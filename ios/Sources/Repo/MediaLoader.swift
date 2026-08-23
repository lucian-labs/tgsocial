// Repo — MediaLoader (PROTOCOL.md §4.10): downloadFile → wait for updateFile → read local.path. Cached by remote.uniqueId.

import Foundation
import TDLibKit
import UIKit

@MainActor
final class MediaLoader {
    private let td: TDClient
    private let cache = NSCache<NSString, UIImage>()
    private var waiters: [Int: [CheckedContinuation<String?, Never>]] = [:]
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    init(td: TDClient) {
        self.td = td
        cache.countLimit = 300
    }

    /// Route `updateFile` here from the update handler.
    func handle(file: File) {
        guard file.local.isDownloadingCompleted else { return }
        resolve(fileId: file.id, path: file.local.path)
    }

    private func resolve(fileId: Int, path: String?) {
        guard let list = waiters.removeValue(forKey: fileId) else { return }
        for w in list { w.resume(returning: path) }
    }

    func cached(_ ref: PhotoRef) -> UIImage? { cache.object(forKey: ref.uniqueId as NSString) }

    /// The blurred minithumbnail, for instant placeholders.
    func minithumbnail(_ ref: PhotoRef) -> UIImage? {
        guard let data = ref.minithumbnail else { return nil }
        return UIImage(data: data)
    }

    func image(for ref: PhotoRef) async -> UIImage? {
        if let hit = cached(ref) { return hit }
        if let running = inflight[ref.uniqueId] { return await running.value }
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            guard let path = await self.localPath(fileId: ref.fileId), let img = UIImage(contentsOfFile: path) else { return nil }
            self.cache.setObject(img, forKey: ref.uniqueId as NSString)
            return img
        }
        inflight[ref.uniqueId] = task
        let result = await task.value
        inflight[ref.uniqueId] = nil
        return result
    }

    private func localPath(fileId: Int) async -> String? {
        let api = td.api
        do {
            let started = try await api.downloadFile(fileId: fileId, limit: 0, offset: 0, priority: 1, synchronous: false)
            if started.local.isDownloadingCompleted, !started.local.path.isEmpty { return started.local.path }
        } catch {
            return nil
        }
        // Wait for updateFile with local.isDownloadingCompleted (PROTOCOL §4.10). A synchronous re-request
        // resolves the same waiter, so a missed update cannot strand the caller.
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            waiters[fileId, default: []].append(c)
            Task { [weak self] in
                let f = try? await api.downloadFile(fileId: fileId, limit: 0, offset: 0, priority: 1, synchronous: true)
                let done = f?.local.isDownloadingCompleted ?? false
                self?.resolve(fileId: fileId, path: done ? f?.local.path : nil)
            }
        }
    }
}
