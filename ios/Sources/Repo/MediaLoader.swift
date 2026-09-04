// Repo — MediaLoader (PROTOCOL.md §4.10, PRODUCT.md §2.11): downloadFile → updateFile → local path.
// Observable per-file state (downloadedSize / expectedSize / downloadedPrefixSize) drives the
// determinate gold progress rings; cancelDownloadFile aborts; priority 1 while visible, 32 on tap;
// `streamableURL` allows playback from the downloaded prefix when TDLib says the file streams.
// Downloads register in the ActivityRegistry so the Status sheet lists them.
//
// Decoded images live in an ImageMemoryCache: bounded by bytes (see ImageCache.swift for the
// budget derivation), decoded through ImageIO at the size the caller will actually draw, and
// dropped wholesale on a memory warning.

import Foundation
import TDLibKit
import UIKit

@MainActor @Observable
final class MediaLoader {
    struct FileState: Equatable {
        var path = ""
        var downloaded: Int64 = 0
        var prefixSize: Int64 = 0
        var expected: Int64 = 0
        var active = false
        var complete = false
        var progress: Double { expected > 0 ? min(1, Double(downloaded) / Double(expected)) : 0 }
    }

    nonisolated static let visiblePriority = 1
    nonisolated static let tappedPriority = 32
    /// Minimum downloaded prefix before a streamable video is handed to the player.
    static let streamMinPrefix: Int64 = 1 << 20

    private(set) var states: [Int: FileState] = [:]
    /// How many times the decoded-image cache has been dropped under memory pressure. Observable
    /// so the Status sheet can show it; also the hook a test or a debug build reads to prove the
    /// warning actually arrived.
    private(set) var imagePurges = 0

    @ObservationIgnored private let td: TDClient
    @ObservationIgnored private let activity: ActivityRegistry
    /// PRODUCT §2.22.4: "Media cannot reach the network because fixture media has no file id."
    ///
    /// Non-nil is the demo, and every route out of this type to TDLib is gated on it *here* rather
    /// than at the thirty call sites in `MediaViews`. That is the whole of the substitution: the
    /// generators answer `download`, and `downloadFile` is not reachable from a fixture — every
    /// fixture id is negative (`DemoMedia.isDemoFileId`) and TDLib's are positive, so a demo id
    /// cannot be mistaken for a real file even by accident.
    ///
    /// Setting it — either direction — ends the previous session's files (`endSession`).
    @ObservationIgnored var demo: DemoMedia? {
        didSet { endSession() }
    }
    /// Byte-bounded (ImageCache.swift). The old `countLimit = 300` with no cost was not a memory
    /// bound at all — 300 full-resolution decodes is multiple gigabytes.
    @ObservationIgnored private let images: ImageMemoryCache
    @ObservationIgnored private var waiters: [Int: [CheckedContinuation<String?, Never>]] = [:]
    @ObservationIgnored private var inflight: [String: Task<UIImage?, Never>] = [:]
    @ObservationIgnored private var memoryWarning: MemoryPressureWatch?

    init(td: TDClient, activity: ActivityRegistry, images: ImageMemoryCache = ImageMemoryCache()) {
        self.td = td
        self.activity = activity
        self.images = images
        memoryWarning = MemoryPressureWatch { [weak self] in self?.purgeImages() }
    }

    /// Bytes of decoded pixels the cache is allowed to hold — surfaced for the Status sheet.
    var imageCacheByteLimit: Int { images.byteLimit }

    /// Everything cached here is one session's files, and no session's paths outlive it: leaving the
    /// demo deletes the world's temp directory (`DemoMedia.discard`), and TDLib's own directory goes
    /// on sign-out. Keeping the completed `FileState`s across that boundary is what breaks the
    /// second demo — `DemoMedia.nextFileId` restarts at `firstFileId` for every `DemoWorld` and
    /// registration is deterministic, so session two asks for the very ids session one completed,
    /// `download` and `streamableURL` both return the deleted path, and the generator never runs
    /// again. §2.22.5 says the demo is droppable and re-enterable; this is what makes that true for
    /// audio, video, the animation and the document, which — unlike images, cached by `uniqueId` —
    /// have nothing but this table to answer from.
    private func endSession() {
        states = [:]
        for list in waiters.values { for waiter in list { waiter.resume(returning: nil) } }
        waiters = [:]
        for task in inflight.values { task.cancel() }
        inflight = [:]
        // Not `purgeImages()`: that counter is the memory-warning one the Status sheet reads, and a
        // session change is not memory pressure. The pixels still go — a real account's photos are
        // not the demo's to hold, and vice versa.
        images.removeAll()
    }

    func state(_ fileId: Int) -> FileState { states[fileId] ?? FileState() }

    /// Route `updateFile` here from the update handler.
    func handle(file: File) { apply(file) }

    private func apply(_ file: File) {
        var s = FileState()
        s.path = file.local.path
        s.downloaded = file.local.downloadedSize
        s.prefixSize = file.local.downloadedPrefixSize
        s.expected = file.expectedSize > 0 ? file.expectedSize : file.size
        s.active = file.local.isDownloadingActive
        s.complete = file.local.isDownloadingCompleted
        let previous = states[file.id]
        states[file.id] = s
        if s.complete {
            resolve(fileId: file.id, path: s.path.isEmpty ? nil : s.path)
        } else if !s.active, previous?.active == true {
            // Stopped without completing: cancelled or failed.
            resolve(fileId: file.id, path: nil)
        }
    }

    private func resolve(fileId: Int, path: String?) {
        guard let list = waiters.removeValue(forKey: fileId) else { return }
        for w in list { w.resume(returning: path) }
    }

    // MARK: Downloads

    /// Starts (or re-prioritises) a download without waiting. Safe to call repeatedly.
    func prefetch(_ fileId: Int, priority: Int = MediaLoader.visiblePriority) {
        if let s = states[fileId], s.complete { return }
        if demo != nil {
            Task { [weak self] in _ = await self?.download(fileId, priority: priority, label: "") }
            return
        }
        let api = td.api
        Task { [weak self] in
            if let f = try? await api.downloadFile(fileId: fileId, limit: 0, offset: 0, priority: priority, synchronous: false) {
                self?.apply(f)
            }
        }
    }

    /// Downloads to completion. nil when the download is cancelled or fails.
    func download(_ fileId: Int, priority: Int, label: String) async -> String? {
        if let s = states[fileId], s.complete, !s.path.isEmpty { return s.path }
        if let demo { return await generate(fileId, with: demo) }
        let api = td.api
        let token = activity.begin(label)
        defer { activity.end(token) }
        do {
            let started = try await api.downloadFile(fileId: fileId, limit: 0, offset: 0, priority: priority, synchronous: false)
            apply(started)
            if started.local.isDownloadingCompleted, !started.local.path.isEmpty { return started.local.path }
        } catch {
            return nil
        }
        // Wait for updateFile (PROTOCOL §4.10). The parallel synchronous request returns when the
        // download succeeds, fails, or is cancelled and resolves the same waiter, so a missed
        // update cannot strand the caller.
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            waiters[fileId, default: []].append(c)
            Task { [weak self] in
                let f = try? await api.downloadFile(fileId: fileId, limit: 0, offset: 0, priority: priority, synchronous: true)
                if let f { self?.apply(f) }
                let done = f?.local.isDownloadingCompleted ?? false
                self?.resolve(fileId: fileId, path: done ? f?.local.path : nil)
            }
        }
    }

    func cancel(_ fileId: Int) {
        // Nothing to cancel in the demo: generation is local and finishes in milliseconds, and a
        // cancel that reached TDLib would be the one request the demo makes.
        guard demo == nil else { return }
        let api = td.api
        Task { _ = try? await api.cancelDownloadFile(fileId: fileId, onlyIfPending: false) }
    }

    /// The demo's stand-in for a download: generate the file, then publish the same `FileState` a
    /// completed download would have, so every progress ring, poster and player downstream reads
    /// exactly what it reads in a real session.
    private func generate(_ fileId: Int, with demo: DemoMedia) async -> String? {
        var pending = FileState()
        pending.active = true
        pending.expected = 1
        states[fileId] = pending
        let generated = await demo.path(fileId: fileId)
        // The session can end mid-generation — a tap on play, then `Leave Demo`. Those bytes are
        // already deleted and `endSession` has cleared the table, so putting a row back here would
        // hand the *next* demo a completed state for a file that no longer exists.
        guard self.demo === demo else { return nil }
        guard let path = generated else {
            states[fileId] = FileState()
            resolve(fileId: fileId, path: nil)
            return nil
        }
        let size = demo.size(fileId: fileId)
        states[fileId] = FileState(path: path, downloaded: size, prefixSize: size,
                                   expected: size, active: false, complete: true)
        resolve(fileId: fileId, path: path)
        return path
    }

    // MARK: Playback URLs

    func localURL(_ fileId: Int) -> URL? {
        guard let s = states[fileId], s.complete, !s.path.isEmpty else { return nil }
        return URL(fileURLWithPath: s.path)
    }

    /// A URL the player may open now: the complete file, or — for TDLib-streamable files —
    /// the partial file once the downloaded prefix covers enough of the head.
    func streamableURL(_ file: FileRef) -> URL? {
        guard let s = states[file.fileId], !s.path.isEmpty else { return nil }
        if s.complete { return URL(fileURLWithPath: s.path) }
        guard file.streamable, s.expected > 0 else { return nil }
        let need = min(max(Self.streamMinPrefix, s.expected / 4), s.expected)
        return s.prefixSize >= need ? URL(fileURLWithPath: s.path) : nil
    }

    /// Starts the download at tapped priority and returns as soon as the file can play
    /// (streamable prefix or complete). nil when the download stops without completing.
    func readyToPlayURL(_ file: FileRef, label: String) async -> URL? {
        if let url = streamableURL(file) { return url }
        if demo != nil {
            // A generated clip is complete or it does not exist; there is no prefix to stream.
            guard let path = await download(file.fileId, priority: Self.tappedPriority, label: label) else { return nil }
            return URL(fileURLWithPath: path)
        }
        let api = td.api
        let token = activity.begin(label)
        defer { activity.end(token) }
        let started = try? await api.downloadFile(fileId: file.fileId, limit: 0, offset: 0,
                                                  priority: Self.tappedPriority, synchronous: false)
        if let started { apply(started) }
        while true {
            if let url = streamableURL(file) { return url }
            let s = state(file.fileId)
            if !s.active, !s.complete { return nil }
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return nil }
        }
    }

    // MARK: Images

    /// Drops every decoded pixel we are only holding speculatively.
    ///
    /// Called from `UIApplication.didReceiveMemoryWarningNotification` (wired in `init`). Views on
    /// screen keep their own `@State` `UIImage`, so nothing on screen goes blank: the feed repaints
    /// from what it already holds, and cards scrolled back into view re-decode lazily from the
    /// local file, which is still on disk. In-flight downloads are deliberately left alone —
    /// cancelling them would strand a progress ring mid-spin for no memory saving.
    func purgeImages() {
        images.removeAll()
        imagePurges += 1
    }

    func cached(_ ref: PhotoRef, _ rendition: ImageRendition) -> UIImage? {
        images.image(ImageMemoryCache.key(ref.uniqueId, rendition))
    }

    /// The blurred minithumbnail, for instant placeholders. TDLib ships these inline at ~40 px, so
    /// they are a few KB decoded and are not worth a cache entry.
    func minithumbnail(_ ref: PhotoRef) -> UIImage? {
        guard let data = ref.minithumbnail else { return nil }
        return UIImage(data: data)
    }

    func image(for ref: PhotoRef, rendition: ImageRendition,
               priority: Int = MediaLoader.visiblePriority,
               label: String = "Downloading photo") async -> UIImage? {
        await decoded(fileId: ref.fileId, uniqueId: ref.uniqueId, rendition: rendition,
                      priority: priority, label: label)
    }

    /// Stickers and other non-photo files that still render as a still image.
    func image(for file: FileRef, rendition: ImageRendition,
               priority: Int = MediaLoader.visiblePriority,
               label: String = "Downloading image") async -> UIImage? {
        await decoded(fileId: file.fileId, uniqueId: file.uniqueId, rendition: rendition,
                      priority: priority, label: label)
    }

    /// The original pixels, for saving to the photo library. Deliberately **not** cached: a
    /// full-resolution decode is precisely the allocation the cache exists to avoid retaining, and
    /// it is released the moment the save completes.
    func originalImage(for ref: PhotoRef, priority: Int = MediaLoader.tappedPriority,
                       label: String = "Downloading photo") async -> UIImage? {
        guard let path = await download(ref.fileId, priority: priority, label: label) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            ImageDecoder.decode(path: path, maxPixelSize: ImageRendition.original.maxPixelSize)
        }.value
    }

    /// Download → downsampled decode → cache, coalescing concurrent callers on the same rendition.
    private func decoded(fileId: Int, uniqueId: String, rendition: ImageRendition,
                         priority: Int, label: String) async -> UIImage? {
        let key = ImageMemoryCache.key(uniqueId, rendition)
        if let hit = images.image(key) { return hit }
        if let running = inflight[key] { return await running.value }
        let maxPixelSize = rendition.maxPixelSize
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            // The entry is cleared from inside the task, not after `await task.value`: a caller
            // whose `.task(id:)` is cancelled mid-await never reaches its own cleanup, and the
            // finished Task — holding a decoded UIImage — would sit in `inflight` for ever.
            defer { self.inflight[key] = nil }
            guard let path = await self.download(fileId, priority: priority, label: label) else { return nil }
            // Off the main actor: a multi-megapixel decode is tens of milliseconds and would drop
            // frames mid-scroll.
            let decodedImage = await Task.detached(priority: .userInitiated) {
                ImageDecoder.decode(path: path, maxPixelSize: maxPixelSize)
            }.value
            guard let decodedImage else { return nil }
            self.images.insert(decodedImage, key: key)
            return decodedImage
        }
        inflight[key] = task
        return await task.value
    }
}
