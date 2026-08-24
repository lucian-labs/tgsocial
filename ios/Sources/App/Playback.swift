// App — playback (PRODUCT.md §2.11 "Player rules"). One audio item at a time through
// AudioPlayback (the now-playing row reads it); VideoCoordinator makes videos pause each
// other; InlinePlayerModel wraps one AVPlayer for inline video / animation / video notes.
// System playback engines only — their transport chrome never appears.

import AVFoundation
import Foundation
import Observation
import UIKit

enum AudioSession {
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }
}

/// The AV resources one player model owns — the AVPlayer and its observer registrations — in an
/// object whose `deinit` is allowed to touch them.
///
/// Two things make this necessary. AVPlayer owns its periodic-time observer and NotificationCenter
/// owns the `didPlayToEnd` token; **neither is released by the observing object going away**, so
/// something has to remove them, and a paused-but-retained AVPlayer keeps its item, decode ring and
/// render buffers alive. And a `@MainActor` class's own `deinit` is nonisolated and cannot reach
/// its isolated stored properties, so it cannot do the removal itself. Holding them here means the
/// release happens whenever the model is dropped — including the paths that never run a view's
/// `onDisappear`: a navigation stack replaced wholesale, a sign-out that drops the model graph.
final class PlayerResources {
    var player: AVPlayer?
    var timeObserver: Any?
    var endObserver: NSObjectProtocol?
    var statusObservation: NSKeyValueObservation?

    /// Removes both observer registrations, invalidates the KVO token, detaches the item — which
    /// drops its decode ring and render buffers now rather than at some later autorelease — and
    /// lets the player go.
    func release() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    deinit { release() }
}

/// The single audio player. Starting another item pauses (replaces) the first; playback
/// continues while scrolling and across tabs; the docked now-playing row mirrors this state.
@MainActor @Observable
final class AudioPlayback {
    struct Item: Equatable {
        let key: String
        let title: String
        let duration: Int
    }

    private(set) var current: Item?
    private(set) var isPlaying = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    /// The item key currently being downloaded before playback.
    var loadingKey: String?
    /// Fires whenever audio starts or resumes. AppModel points it at the video coordinator so
    /// starting audio pauses an audible inline video — §2.11's one-sound rule in both directions.
    @ObservationIgnored var onWillPlay: (() -> Void)?

    @ObservationIgnored private let resources = PlayerResources()
    private var player: AVPlayer? { resources.player }

    var progress: Double { duration > 0 ? min(1, elapsed / duration) : 0 }

    func isCurrent(_ key: String) -> Bool { current?.key == key }

    func play(_ item: Item, url: URL) {
        AudioSession.activate()
        onWillPlay?()
        resources.release()
        let p = AVPlayer(url: url)
        resources.player = p
        current = item
        duration = Double(item.duration)
        elapsed = 0
        loadingKey = nil
        resources.timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                           queue: .main) { [weak self] time in
            guard let self else { return }
            self.elapsed = time.seconds.isFinite ? time.seconds : 0
            if let d = self.player?.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
        }
        resources.endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                       object: p.currentItem, queue: .main) { [weak self] _ in
            self?.stop()
        }
        p.play()
        isPlaying = true
    }

    func toggle() {
        guard let player else { return }
        if isPlaying { player.pause() } else { AudioSession.activate(); onWillPlay?(); player.play() }
        isPlaying.toggle()
    }

    func pause() {
        guard isPlaying else { return }
        player?.pause()
        isPlaying = false
    }

    func seek(toFraction f: Double) {
        guard let player, duration > 0 else { return }
        let target = min(max(f, 0), 1) * duration
        elapsed = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func stop() {
        resources.release()
        current = nil
        isPlaying = false
        elapsed = 0
        duration = 0
    }
}

/// Videos pause when another video starts (PRODUCT §2.11). Inline players compare
/// `activeId` to their own id and pause when it moves on.
@MainActor @Observable
final class VideoCoordinator {
    private(set) var activeId: String?

    func willPlay(_ id: String, pausing audio: AudioPlayback) {
        activeId = id
        audio.pause()
    }

    func stopped(_ id: String) {
        if activeId == id { activeId = nil }
    }

    /// Audio is starting: clearing `activeId` makes every audible inline player's `onChange`
    /// pause it — the reverse direction of `willPlay` (§2.11, one sound at a time).
    func pauseActive() {
        activeId = nil
    }
}

/// One AVPlayer for an inline surface (video, animation loop, video note) or a viewer page.
/// `failed` flips when the item errors — the partial-file streaming fallback reloads it once
/// the download completes.
@MainActor @Observable
final class InlinePlayerModel {
    private(set) var isPlaying = false
    private(set) var elapsed: Double = 0
    var duration: Double = 0
    private(set) var failed = false

    var loop = false
    var muted = false

    /// The player and its observer registrations. Held in a box so they are released even when the
    /// model is dropped without `teardown()` ever being called — see `PlayerResources`.
    @ObservationIgnored private let resources = PlayerResources()
    var player: AVPlayer? { resources.player }

    var progress: Double { duration > 0 ? min(1, elapsed / duration) : 0 }

    func load(url: URL, startAt: Double = 0) {
        teardown()
        failed = false
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.isMuted = muted
        resources.player = p
        resources.statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                self?.failed = true
                self?.isPlaying = false
            }
        }
        resources.timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                           queue: .main) { [weak self] time in
            guard let self else { return }
            self.elapsed = time.seconds.isFinite ? time.seconds : 0
            if let d = self.player?.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
        }
        resources.endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                       object: item, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.loop {
                self.player?.seek(to: .zero)
                self.player?.play()
            } else {
                self.isPlaying = false
                self.player?.seek(to: .zero)
                self.elapsed = 0
            }
        }
        if startAt > 0 { p.seek(to: CMTime(seconds: startAt, preferredTimescale: 600)) }
    }

    func play() {
        guard let player else { return }
        if !muted { AudioSession.activate() }
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(toFraction f: Double) {
        guard let player, duration > 0 else { return }
        let target = min(max(f, 0), 1) * duration
        elapsed = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    /// Releases the player, its item and both observer registrations. Called from every media
    /// view's `onDisappear`: a *paused* player still holds its item, decode ring and render
    /// buffers, so pausing alone left a scrolled-past video card costing memory for the rest of
    /// the session.
    func teardown() {
        resources.release()
        isPlaying = false
        elapsed = 0
        duration = 0
    }
}

/// Save to the photo library with a completion (UIKit's C-style callback needs an NSObject target).
final class MediaSaver: NSObject {
    private var completion: ((String?) -> Void)?

    func save(image: UIImage, done: @escaping (String?) -> Void) {
        completion = done
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(image(_:didFinishSavingWithError:contextInfo:)), nil)
    }

    func save(videoPath: String, done: @escaping (String?) -> Void) {
        guard UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(videoPath) else {
            done("This video can't be saved.")
            return
        }
        completion = done
        UISaveVideoAtPathToSavedPhotosAlbum(videoPath, self, #selector(video(_:didFinishSavingWithError:contextInfo:)), nil)
    }

    @objc private func image(_ image: UIImage, didFinishSavingWithError error: NSError?, contextInfo: UnsafeRawPointer) {
        completion?(error?.localizedDescription)
        completion = nil
    }

    @objc private func video(_ videoPath: String, didFinishSavingWithError error: NSError?, contextInfo: UnsafeRawPointer) {
        completion?(error?.localizedDescription)
        completion = nil
    }
}

/// The system share sheet (the sanctioned system surface for Share, PRODUCT §2.11).
@MainActor
enum ShareSheet {
    static func present(url: URL) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = vc.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        top.present(vc, animated: true)
    }
}
