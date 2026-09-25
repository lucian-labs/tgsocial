// Repo — reading a WaveLoop drop off its owner's PDS (PROTOCOL.md §12.12, PRODUCT.md §2.36.1).
//
// Everything a drop costs is bounded here, rule by rule, because none of it was measured against a
// real drop — no drop existed on the network on 2026-09-25 (§12.12 "Measured"):
//   - records: one read per drop ref, cached in memory, at most 64 (rule 3);
//   - blobs: whole-file downloads to disk (getBlob ignores `Range`, rule 5), in a lane of two apart
//     from §12.4's four, refused over the lexicon cap before a byte and aborted at the byte they
//     pass it (rule 4), into one disk cache of 16 files / 200 MB checked against the CID (rule 6);
//   - pixels: decoded at the size drawn, through ImageIO, into the app's ONE decoded-image budget —
//     the `ImageMemoryCache` MediaLoader uses — never a cache of our own (rule 9).
// The pure half (which records are drops, what each kind needs) is `Protocol/Drop.swift`.

import CoreGraphics
import CoreMotion
import CryptoKit
import Foundation
import ImageIO
import UIKit

/// Where a drop's blobs come from: its owner and the PDS their DID document names (rule 2).
struct DropSource: Equatable, Hashable {
    let did: String
    let pds: URL

    func url(_ blob: DropBlob) -> URL? { Atproto.blobURL(pds: pds, did: did, cid: blob.cid) }
}

/// Rule 3's answer for one drop ref. `.later` is "no answer" — never cached.
enum DropResolution: Equatable {
    case drop(DropRecord, DropSource)
    case none
    case later(rateLimited: Int?)
}

/// Rule 5: a download the reader asked for goes ahead of one the scroll asked for.
enum DropPriority: Int, Comparable {
    case screen = 0, tap = 1
    static func < (a: DropPriority, b: DropPriority) -> Bool { a.rawValue < b.rawValue }
}

enum DropFailure: Error, Equatable {
    /// Over the field's cap or the declared size (rule 4), before or during the body.
    case overCap
    case status(Int)
    case rateLimited(Int)
    /// The bytes are not the ones the CID names (rule 6).
    case mismatch
    case unreachable
    case io
    case cancelled
}

/// One blob's download, as the ring reads it (PRODUCT §2.11's determinate ring).
struct DropFileState: Equatable {
    var received: Int64 = 0
    var expected: Int64 = 0
    var active = false
    var url: URL?
    var failure: DropFailure?
    var progress: Double { expected > 0 ? min(1, Double(received) / Double(expected)) : 0 }
}

// MARK: - The wire

/// What a blob download sees: the response head, then the body in chunks. A stream, not
/// `URLSession.download`, because rule 4 aborts a body at the byte it passes the cap — a finished
/// download to a temp file would already have spent the bandwidth and the disk.
enum BlobEvent {
    case response(HTTPURLResponse)
    case data(Data)
}

protocol BlobSource: Sendable {
    func stream(_ request: URLRequest) -> AsyncThrowingStream<BlobEvent, Error>
}

/// URLSession with a per-task delegate relaying the head and each chunk. Ending the stream (a throw
/// in the consumer, a cancelled task) cancels the data task, so an aborted blob stops downloading.
final class URLSessionBlobSource: BlobSource, @unchecked Sendable {
    let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        // Idle time between packets, not the whole file: a 50 MB blob on a slow link takes minutes.
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 15 * 60
        // CIDs name immutable bytes; the disk cache is the only cache (rule 6).
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": "tgsocial (+https://github.com/lucian-labs/tgsocial)"]
        session = URLSession(configuration: config)
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<BlobEvent, Error> {
        AsyncThrowingStream { continuation in
            let relay = Relay(continuation)
            let task = session.dataTask(with: request)
            task.delegate = relay
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }

    private final class Relay: NSObject, URLSessionDataDelegate {
        let continuation: AsyncThrowingStream<BlobEvent, Error>.Continuation
        init(_ c: AsyncThrowingStream<BlobEvent, Error>.Continuation) { continuation = c }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse { continuation.yield(.response(http)) }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            continuation.yield(.data(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
    }
}

enum DropDownload {
    /// One blob to `tmp`, whole (rule 5). Nonisolated and awaited directly, so it runs off the main
    /// actor and a cancelled caller cancels it. Returns the byte count.
    ///
    /// Rule 4 on the wire: a `content-length` over the limit is refused before the body is read,
    /// and a body that runs past it is aborted at that byte. The limit is the field's cap, or the
    /// declared size when the record gave one — a PDS serving more than the record said is serving
    /// something else. Rule 6: a `bafkrei…` CID is checked against the SHA-256 of what arrived.
    static func run(source: BlobSource, request: URLRequest, blob: DropBlob, to tmp: URL,
                    progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> Int64 {
        let limit = Int64(min(blob.cap, blob.size ?? blob.cap))
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else { throw DropFailure.io }
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: tmp) } catch { throw DropFailure.io }
        defer { try? handle.close() }
        let digest = Atproto.sha256Digest(ofCid: blob.cid)
        var hasher = SHA256()
        var received: Int64 = 0
        var expected = Int64(blob.size ?? 0)
        var reported: Int64 = 0
        var sawResponse = false
        do {
            for try await event in source.stream(request) {
                try Task.checkCancellation()
                switch event {
                case .response(let r):
                    sawResponse = true
                    if r.statusCode == 429 { throw DropFailure.rateLimited(AtprotoHTTP.retryAfter(r)) }
                    guard (200..<300).contains(r.statusCode) else { throw DropFailure.status(r.statusCode) }
                    let length = r.expectedContentLength
                    if length > limit { throw DropFailure.overCap }
                    if length > 0 { expected = length }
                case .data(let d):
                    guard sawResponse else { throw DropFailure.io }
                    received += Int64(d.count)
                    if received > limit { throw DropFailure.overCap }
                    do { try handle.write(contentsOf: d) } catch { throw DropFailure.io }
                    if digest != nil { hasher.update(data: d) }
                    // Every 256 KB, not every chunk: the ring cannot show finer than that, and each
                    // report is a hop to the main actor.
                    if received - reported >= 256 << 10 {
                        reported = received
                        progress(received, expected)
                    }
                }
            }
        } catch let f as DropFailure {
            throw f
        } catch is CancellationError {
            throw DropFailure.cancelled
        } catch {
            if Task.isCancelled { throw DropFailure.cancelled }
            throw DropFailure.unreachable
        }
        try Task.checkCancellation()
        guard sawResponse else { throw DropFailure.unreachable }
        if let digest, Data(hasher.finalize()) != digest { throw DropFailure.mismatch }
        progress(received, max(expected, received))
        return received
    }
}

// MARK: - The disk cache (rule 6)

/// One directory, keyed by CID, at most 16 files and 200 MB, least recently used out first, with
/// pinned files — the one being played, decoded or shown — never evicted. A CID names its bytes, so
/// an entry is never stale and never revalidated. Main-actor only: every call is a stat, a rename
/// or an unlink, and the downloads that write the bytes do so to a temp file off the actor.
@MainActor
final class DropBlobCache {
    nonisolated static let fileLimit = 16
    nonisolated static let byteLimit: Int64 = 200_000_000

    let directory: URL
    let fileLimit: Int
    let byteLimit: Int64
    private struct Entry { var url: URL; var size: Int64; var used: Date }
    private var entries: [String: Entry] = [:]
    private var pins: [String: Int] = [:]
    private var tick = Date.distantPast

    init(directory: URL? = nil, fileLimit: Int = DropBlobCache.fileLimit, byteLimit: Int64 = DropBlobCache.byteLimit) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("drop-blobs")
        self.directory = base
        self.fileLimit = fileLimit
        self.byteLimit = byteLimit
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Rebuilt from the directory: the index is memory, the bytes survive a relaunch. Temp files
        // from a download a crash interrupted are removed, never admitted.
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        for url in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: keys)) ?? [] {
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension != "part", Atproto.isBlobCid(name) else { try? FileManager.default.removeItem(at: url); continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            entries[name] = Entry(url: url, size: Int64(values?.fileSize ?? 0), used: values?.contentModificationDate ?? .distantPast)
        }
        evict()
    }

    var count: Int { entries.count }
    var totalBytes: Int64 { entries.values.reduce(0) { $0 + $1.size } }
    var pinnedCount: Int { pins.values.filter { $0 > 0 }.count }

    func url(for cid: String) -> URL? {
        guard var e = entries[cid] else { return nil }
        guard FileManager.default.fileExists(atPath: e.url.path) else { entries[cid] = nil; return nil }
        e.used = now()
        entries[cid] = e
        return e.url
    }

    /// A fresh temp path inside the directory, so admitting it is a rename on the same volume.
    func temporaryURL() -> URL { directory.appendingPathComponent(UUID().uuidString + ".part") }

    /// A completed, checked download enters the cache; then LRU eviction to the bounds.
    @discardableResult
    func admit(_ tmp: URL, cid: String, fileExtension: String) -> URL? {
        let dest = directory.appendingPathComponent("\(cid).\(fileExtension)")
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: tmp, to: dest) } catch {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        entries[cid] = Entry(url: dest, size: size, used: now())
        evict()
        return entries[cid]?.url
    }

    func pin(_ cid: String) { pins[cid, default: 0] += 1 }
    func unpin(_ cid: String) {
        guard let n = pins[cid] else { return }
        if n <= 1 { pins[cid] = nil } else { pins[cid] = n - 1 }
        evict()
    }

    /// Least recently used out first, skipping pins, until both bounds hold. A pinned file can hold
    /// the cache over its bounds for as long as it is on screen; it is released and evicted after.
    private func evict() {
        let order = entries.sorted { $0.value.used < $1.value.used }.map(\.key)
        var count = entries.count
        var bytes = totalBytes
        for cid in order where count > fileLimit || bytes > byteLimit {
            guard (pins[cid] ?? 0) == 0, let e = entries[cid] else { continue }
            try? FileManager.default.removeItem(at: e.url)
            entries[cid] = nil
            count -= 1
            bytes -= e.size
        }
    }

    func removeAll() {
        for e in entries.values { try? FileManager.default.removeItem(at: e.url) }
        entries = [:]
        pins = [:]
    }

    /// A strictly increasing clock, so two admissions inside one timer tick still order.
    private func now() -> Date {
        let d = Date()
        tick = d > tick ? d : tick.addingTimeInterval(0.000_001)
        return tick
    }
}

// MARK: - Device motion (rule 11)

/// One device-motion source for the whole app, running while at least one depth view is on screen
/// and stopped when none is. Each view reads the current attitude and subtracts the one it saw when
/// it came on screen. No permission prompt on iOS, unlike the web's DeviceOrientationEvent. On a
/// Mac `isDeviceMotionAvailable` is false and nothing starts; the pointer drives depth there.
@MainActor
final class DropMotion {
    private let manager = CMMotionManager()
    private(set) var subscribers = 0
    /// Degrees. Roll is the left-right tilt, pitch front-back.
    private(set) var roll = 0.0
    private(set) var pitch = 0.0
    private(set) var hasReading = false

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func subscribe() {
        subscribers += 1
        guard subscribers == 1, manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let a = motion?.attitude else { return }
            self.roll = a.roll * 180 / .pi
            self.pitch = a.pitch * 180 / .pi
            self.hasReading = true
        }
    }

    func unsubscribe() {
        guard subscribers > 0 else { return }
        subscribers -= 1
        guard subscribers == 0 else { return }
        manager.stopDeviceMotionUpdates()
        hasReading = false
    }
}

// MARK: - The store

@MainActor @Observable
final class DropStore {
    /// Rule 3.
    static let recordLimit = 64
    /// Rule 5: two blob downloads in flight, apart from §12.4's four requests.
    static let laneWidth = 2

    private(set) var files: [String: DropFileState] = [:]

    @ObservationIgnored let reader: AtprotoReader
    @ObservationIgnored let blobs: BlobSource
    /// The app's one decoded-image budget, shared with MediaLoader (rule 9).
    @ObservationIgnored let images: ImageMemoryCache
    @ObservationIgnored let disk: DropBlobCache
    @ObservationIgnored let motion = DropMotion()
    @ObservationIgnored private let activity: ActivityRegistry?
    @ObservationIgnored private let now: () -> Date

    @ObservationIgnored private var records: [String: DropResolution] = [:]
    @ObservationIgnored private var recordOrder: [String] = []
    @ObservationIgnored private var recordTasks: [String: Task<DropResolution, Never>] = [:]

    private final class Download {
        var task: Task<Void, Never>?
        var priority: DropPriority
        /// How many on-screen cards want it. A tapped download ignores this (rule 5).
        var demand = 0
        /// Whoever is waiting on THIS download. Per download, not per CID: a cancelled download
        /// can still be unwinding when a fresh one for the same CID starts (`fetch`), and the old
        /// one's `.cancelled` must reach only the callers that joined it.
        var waiters: [CheckedContinuation<URL?, Never>] = []
        init(priority: DropPriority) { self.priority = priority }
        var isCancelled: Bool { task?.isCancelled ?? false }
    }
    @ObservationIgnored private var downloads: [String: Download] = [:]
    @ObservationIgnored private var inLane = 0
    private struct LaneWaiter { let id: UUID; let priority: DropPriority; let continuation: CheckedContinuation<Void, Error> }
    @ObservationIgnored private var laneWaiters: [LaneWaiter] = []
    /// Rule 5: a 429 from a PDS backs off that host under §12.4's rule.
    @ObservationIgnored private var hostBackoff: [String: Date] = [:]
    @ObservationIgnored private var decodes: [String: Task<UIImage?, Never>] = [:]
    @ObservationIgnored private var memoryWarning: MemoryPressureWatch?

    // What the tests measure.
    @ObservationIgnored private(set) var recordReads = 0
    @ObservationIgnored private(set) var blobRequests = 0
    @ObservationIgnored private(set) var peakLane = 0
    @ObservationIgnored private(set) var decodeCount = 0
    /// Rule 11: one model scene across the app. Counted by the scene view itself.
    @ObservationIgnored var liveModelScenes = 0
    /// Live depth views, so a test can see every one of them go on disappear.
    @ObservationIgnored var liveDepthViews = 0

    init(reader: AtprotoReader, blobs: BlobSource = URLSessionBlobSource(), images: ImageMemoryCache,
         disk: DropBlobCache? = nil, activity: ActivityRegistry? = nil, now: @escaping () -> Date = { Date() }) {
        self.reader = reader
        self.blobs = blobs
        self.images = images
        self.disk = disk ?? DropBlobCache()
        self.activity = activity
        self.now = now
        // Rule 9: decoded drop pixels live in the shared cache, which MediaLoader already purges on
        // a warning. The in-flight decode table is ours, and so is the record cache — both are
        // memory, and neither is worth keeping under pressure.
        memoryWarning = MemoryPressureWatch { [weak self] in self?.purgeMemory() }
    }

    // MARK: Records (rules 2 and 3)

    func cached(_ ref: String) -> DropResolution? { records[ref] }

    /// The drop behind `ref`, read at most once (rule 1's "one read per drop ref") however many
    /// cards ask at once.
    func resolve(_ ref: String) async -> DropResolution {
        if let hit = records[ref] {
            touch(ref)
            return hit
        }
        if let running = recordTasks[ref] { return await running.value }
        let reader = self.reader
        recordReads += 1
        let task = Task { await Self.read(ref, reader: reader) }
        recordTasks[ref] = task
        let result = await task.value
        recordTasks[ref] = nil
        if case .later = result { return result }
        remember(ref, result)
        return result
    }

    private func remember(_ ref: String, _ r: DropResolution) {
        records[ref] = r
        touch(ref)
        while recordOrder.count > Self.recordLimit {
            records[recordOrder.removeFirst()] = nil
        }
    }

    private func touch(_ ref: String) {
        recordOrder.removeAll { $0 == ref }
        recordOrder.append(ref)
    }

    var recordCount: Int { records.count }

    /// Rule 2, on the network, inside §12.4's four and its 429 back-off. Definitive answers are
    /// rule 3's list; everything else is `.later`, and the card asks again the next time it is on
    /// screen.
    nonisolated static func read(_ ref: String, reader: AtprotoReader) async -> DropResolution {
        guard let at = Atproto.parseAtUri(ref), at.collection == Atproto.dropCollection else { return .none }
        do {
            return try await reader.limited { () async throws -> DropResolution in
                let doc: DidDocument
                do { doc = try await reader.identity.document(at.did) } catch let e as AtprotoError {
                    if case .http(let status, _, _, _) = e, status == 404 || status == 410 { return DropResolution.none }
                    throw e
                }
                guard let pds = doc.pds, let url = Atproto.dropRecordURL(pds: pds, ref: ref) else { return .none }
                do {
                    let json = try await AtprotoHTTP.getJSON(reader.transport, url)
                    guard let record = Atproto.dropRecord(json, ref: ref) else { return .none }
                    return .drop(record, DropSource(did: at.did, pds: pds))
                } catch let e as AtprotoError where e.isRecordNotFound {
                    return .none
                }
            }
        } catch let e as AtprotoError {
            if case .rateLimited(let s) = e { return .later(rateLimited: s) }
            return .later(rateLimited: nil)
        } catch {
            return .later(rateLimited: nil)
        }
    }

    // MARK: Blobs (rules 4–6)

    func state(_ cid: String) -> DropFileState {
        if let s = files[cid] { return s }
        if let url = disk.url(for: cid) { return DropFileState(received: 0, expected: 0, active: false, url: url) }
        return DropFileState()
    }

    func localURL(_ cid: String) -> URL? { disk.url(for: cid) }

    /// Starts (or joins) a download without waiting. A file already on disk costs a stat.
    func fetch(_ blob: DropBlob, from source: DropSource, priority: DropPriority) {
        if let url = disk.url(for: blob.cid) {
            files[blob.cid] = DropFileState(received: 0, expected: 0, active: false, url: url)
            return
        }
        // A cancelled download stays in the table until its task has unwound across actor hops.
        // Joining it would hand this caller its `.cancelled`: a card scrolled away and straight
        // back (or a lazy stack's disappear/appear on relayout) would read that as a failure and
        // fall back to the link card for good. A cancelled one is never joined; a fresh one
        // replaces it, and the old one's end leaves the new one's state alone (`run`).
        if let running = downloads[blob.cid], !running.isCancelled {
            if priority == .screen { running.demand += 1 }
            if priority > running.priority { running.priority = priority }
            return
        }
        let d = Download(priority: priority)
        if priority == .screen { d.demand = 1 }
        downloads[blob.cid] = d
        var s = DropFileState()
        s.active = true
        s.expected = Int64(blob.size ?? 0)
        files[blob.cid] = s
        d.task = Task { [weak self] in await self?.run(blob, from: source, download: d) }
    }

    /// An on-screen card left the screen: its demand goes, and a screen-priority download nobody
    /// else wants is cancelled (rule 5). A tapped download keeps running.
    func release(_ cid: String) {
        guard let d = downloads[cid] else { return }
        d.demand = max(0, d.demand - 1)
        if d.demand == 0, d.priority == .screen { d.task?.cancel() }
    }

    /// The reader cancelled (the ring) or left the viewer: whatever its priority.
    func cancel(_ cid: String) {
        downloads[cid]?.task?.cancel()
    }

    /// Waits for the file; nil when the download failed or was cancelled.
    func file(_ cid: String) async -> URL? {
        if let url = disk.url(for: cid) { return url }
        guard let d = downloads[cid] else { return nil }
        return await withCheckedContinuation { d.waiters.append($0) }
    }

    /// Fetches every blob and waits for all of them; nil when any fails.
    func files(_ list: [DropBlob], from source: DropSource, priority: DropPriority) async -> [String: URL]? {
        for b in list { fetch(b, from: source, priority: priority) }
        var out: [String: URL] = [:]
        for b in list {
            guard let url = await file(b.cid) else { return nil }
            out[b.cid] = url
        }
        return out
    }

    /// Bytes received over bytes expected across `list`, for one ring over several files.
    func progress(_ list: [DropBlob]) -> Double {
        var got: Int64 = 0
        var want: Int64 = 0
        for b in list {
            let s = state(b.cid)
            let expected = max(s.expected, Int64(b.size ?? 0))
            if s.url != nil {
                let size = max(expected, s.received, 1)
                got += size; want += size
            } else {
                got += s.received; want += max(expected, s.received)
            }
        }
        return want > 0 ? min(1, Double(got) / Double(want)) : 0
    }

    func failure(_ list: [DropBlob]) -> DropFailure? { list.lazy.compactMap { self.files[$0.cid]?.failure }.first }

    func pin(_ cid: String) { disk.pin(cid) }
    func unpin(_ cid: String) { disk.unpin(cid) }

    var activeDownloads: Int { downloads.count }
    /// Downloads holding a lane slot, and downloads waiting for one (rule 5) — for the tests.
    var laneBusy: Int { inLane }
    var laneQueued: Int { laneWaiters.count }

    private func run(_ blob: DropBlob, from source: DropSource, download: Download) async {
        let cid = blob.cid
        var outcome: Result<URL, DropFailure>
        do {
            try await acquireLane(download.priority)
            defer { releaseLane() }
            outcome = await transfer(blob, from: source, download: download)
        } catch {
            outcome = .failure(.cancelled)
        }
        let url: URL?
        switch outcome {
        case .success(let u): url = u
        case .failure: url = nil
        }
        // Superseded: a fresh download for this CID started after this one was cancelled. The
        // table row and the ring's state are the fresh one's now; this one only answers its own.
        guard downloads[cid] === download else {
            for w in download.waiters { w.resume(returning: url) }
            download.waiters = []
            return
        }
        downloads[cid] = nil
        var s = files[cid] ?? DropFileState()
        s.active = false
        switch outcome {
        case .success(let u):
            s.url = u
            s.failure = nil
        case .failure(let f):
            s.failure = f
            s.url = nil
        }
        files[cid] = s
        for w in download.waiters { w.resume(returning: s.url) }
        download.waiters = []
        pruneStates()
    }

    /// The ring's table is memory too: finished rows past twice the disk cache's file count go —
    /// the disk answers for a completed file, and a failure only matters to the card that saw it.
    private func pruneStates() {
        let limit = disk.fileLimit * 2
        guard files.count > limit else { return }
        for (cid, s) in files where !s.active && downloads[cid] == nil {
            files[cid] = nil
            if files.count <= limit { break }
        }
    }

    private func transfer(_ blob: DropBlob, from source: DropSource, download: Download) async -> Result<URL, DropFailure> {
        guard let url = source.url(blob), let host = url.host else { return .failure(.io) }
        if let until = hostBackoff[host], until > now() {
            return .failure(.rateLimited(Int(until.timeIntervalSince(now()).rounded(.up))))
        }
        blobRequests += 1
        var request = URLRequest(url: url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let tmp = disk.temporaryURL()
        let token = activity?.begin("Downloading drop")
        defer { if let token { activity?.end(token) } }
        let cid = blob.cid
        do {
            _ = try await DropDownload.run(source: blobs, request: request, blob: blob, to: tmp) { [weak self, weak download] got, want in
                Task { @MainActor [weak self, weak download] in
                    // Only the current download moves the ring; a superseded one is unwinding.
                    guard let self, let download, self.downloads[cid] === download, var s = self.files[cid], s.active else { return }
                    s.received = got
                    if want > 0 { s.expected = want }
                    self.files[cid] = s
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            let f = (error as? DropFailure) ?? .unreachable
            if case .rateLimited(let seconds) = f { hostBackoff[host] = now().addingTimeInterval(TimeInterval(seconds)) }
            return .failure(Task.isCancelled ? .cancelled : f)
        }
        guard let admitted = disk.admit(tmp, cid: blob.cid, fileExtension: blob.fileExtension) else { return .failure(.io) }
        return .success(admitted)
    }

    private func acquireLane(_ priority: DropPriority) async throws {
        try Task.checkCancellation()
        if inLane < Self.laneWidth {
            inLane += 1
            peakLane = max(peakLane, inLane)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                laneWaiters.append(LaneWaiter(id: id, priority: priority, continuation: c))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.dropWaiter(id) }
        }
    }

    private func dropWaiter(_ id: UUID) {
        guard let i = laneWaiters.firstIndex(where: { $0.id == id }) else { return }
        laneWaiters.remove(at: i).continuation.resume(throwing: CancellationError())
    }

    /// Hands the slot to the highest-priority waiter, first come first served within a priority.
    private func releaseLane() {
        guard let best = laneWaiters.indices.max(by: { laneWaiters[$0].priority < laneWaiters[$1].priority || (laneWaiters[$0].priority == laneWaiters[$1].priority && $0 > $1) }) else {
            inLane -= 1
            return
        }
        laneWaiters.remove(at: best).continuation.resume()
    }

    // MARK: Pixels (rule 9)

    /// Card-width rendition for eyes, images and posters; the depth map at half that, one channel.
    enum Rendition {
        case card, fullScreen, depthMap
        var tag: String {
            switch self {
            case .card: return "card"
            case .fullScreen: return "full"
            case .depthMap: return "dmap"
            }
        }
        @MainActor var maxPixelSize: Int {
            switch self {
            case .card: return ScreenPixels.width
            case .fullScreen: return ScreenPixels.longestEdge
            case .depthMap: return max(ScreenPixels.width / 2, 1)
            }
        }
    }

    static func cacheKey(_ cid: String, _ r: Rendition) -> String { "drop:\(cid)#\(r.tag)" }

    func cachedImage(_ cid: String, _ r: Rendition) -> UIImage? { images.image(Self.cacheKey(cid, r)) }

    /// The file's pixels at `r`, decoded once and charged to the shared budget. The file must be on
    /// disk already; nothing here downloads.
    func image(_ cid: String, _ r: Rendition) async -> UIImage? {
        let key = Self.cacheKey(cid, r)
        if let hit = images.image(key) { return hit }
        if let running = decodes[key] { return await running.value }
        guard let url = disk.url(for: cid) else { return nil }
        let maxPixels = r.maxPixelSize
        let gray = r == .depthMap
        decodeCount += 1
        let task = Task<UIImage?, Never> { [weak self] in
            defer { self?.decodes[key] = nil }
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.decode(path: url.path, maxPixelSize: maxPixels, gray: gray)
            }.value
            guard let decoded else { return nil }
            self?.images.insert(decoded, key: key)
            return decoded
        }
        decodes[key] = task
        return await task.value
    }

    /// ImageIO's thumbnail decode (never a full decode then a resize — rule 9), and for a depth map
    /// a redraw into one 8-bit channel: the shader reads one channel, and a quarter of the bytes of
    /// RGBA is the difference between 0.33 MB and 1.3 MB per card.
    nonisolated static func decode(path: String, maxPixelSize: Int, gray: Bool) -> UIImage? {
        guard let image = ImageDecoder.decode(path: path, maxPixelSize: maxPixelSize) else { return nil }
        guard gray, let cg = image.cgImage else { return image }
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return image }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let out = ctx.makeImage() else { return image }
        return UIImage(cgImage: out)
    }

    // MARK: Clearing

    private func purgeMemory() {
        records = [:]
        recordOrder = []
    }

    /// PROTOCOL §7: the last one out clears the drop caches, memory and disk.
    func clear() {
        for d in downloads.values {
            d.task?.cancel()
            // Their runs will find themselves superseded; answer the waiters now.
            for w in d.waiters { w.resume(returning: nil) }
            d.waiters = []
        }
        downloads = [:]
        records = [:]
        recordOrder = []
        files = [:]
        hostBackoff = [:]
        disk.removeAll()
    }
}
