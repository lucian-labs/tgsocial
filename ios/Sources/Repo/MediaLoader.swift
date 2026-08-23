// Repo — MediaLoader (PROTOCOL.md §4.10, PRODUCT.md §2.11): downloadFile → updateFile → local path.
// Observable per-file state (downloadedSize / expectedSize / downloadedPrefixSize) drives the
// determinate gold progress rings; cancelDownloadFile aborts; priority 1 while visible, 32 on tap;
// `streamableURL` allows playback from the downloaded prefix when TDLib says the file streams.
// Downloads register in the ActivityRegistry so the Status sheet lists them.

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

    @ObservationIgnored private let td: TDClient
    @ObservationIgnored private let activity: ActivityRegistry
    @ObservationIgnored private let cache = NSCache<NSString, UIImage>()
    @ObservationIgnored private var waiters: [Int: [CheckedContinuation<String?, Never>]] = [:]
    @ObservationIgnored private var inflight: [String: Task<UIImage?, Never>] = [:]

    init(td: TDClient, activity: ActivityRegistry) {
        self.td = td
        self.activity = activity
        cache.countLimit = 300
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
        let api = td.api
        Task { _ = try? await api.cancelDownloadFile(fileId: fileId, onlyIfPending: false) }
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

    func cached(_ ref: PhotoRef) -> UIImage? { cache.object(forKey: ref.uniqueId as NSString) }

    /// The blurred minithumbnail, for instant placeholders.
    func minithumbnail(_ ref: PhotoRef) -> UIImage? {
        guard let data = ref.minithumbnail else { return nil }
        return UIImage(data: data)
    }

    func image(for ref: PhotoRef, priority: Int = MediaLoader.visiblePriority,
               label: String = "Downloading photo") async -> UIImage? {
        if let hit = cached(ref) { return hit }
        if let running = inflight[ref.uniqueId] { return await running.value }
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            guard let path = await self.download(ref.fileId, priority: priority, label: label),
                  let img = UIImage(contentsOfFile: path) else { return nil }
            self.cache.setObject(img, forKey: ref.uniqueId as NSString)
            return img
        }
        inflight[ref.uniqueId] = task
        let result = await task.value
        inflight[ref.uniqueId] = nil
        return result
    }
}
