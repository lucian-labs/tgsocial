// Repo — the decoded-image cache and the downsampling decoder that MediaLoader sits on.
//
// Why this file exists. An NSCache bounded only by `countLimit` is not a memory bound: 300 photos
// decoded at sensor resolution (a 12 MP shot is 4032 × 3024 × 4 B ≈ 48 MB once decoded) is well
// over a gigabyte of live pixels. iOS jetsams the app long before an object count of 300 is
// reached, and a jetsam under heavy pressure is what the user reports as "SpringBoard crashed".
//
// Two rules follow, and everything here implements them:
//   1. Bytes — not object count — are the binding constraint (`ImageMemoryCache`).
//   2. A photo is never decoded larger than the pixels it will actually occupy (`ImageDecoder`,
//      via CGImageSourceCreateThumbnailAtIndex; `UIImage(contentsOfFile:)` has no size knob).

import CoreGraphics
import Foundation
import ImageIO
import UIKit
import os

// MARK: - Screen metrics

/// The screen in *pixels*, resolved once. Renditions are expressed in pixels because that is the
/// unit `kCGImageSourceThumbnailMaxPixelSize` speaks.
@MainActor
enum ScreenPixels {
    private static let metrics: (width: Int, longest: Int, scale: CGFloat) = {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen
        // Fallback for the window before any scene connects: a large modern iPhone, so an early
        // decode is over-sized rather than blurry. In practice the first decode happens well after
        // the scene is up, so this is belt and braces.
        let bounds = screen?.bounds ?? CGRect(x: 0, y: 0, width: 440, height: 956)
        let scale = screen?.scale ?? 3
        return (Int((bounds.width * scale).rounded()),
                Int((max(bounds.width, bounds.height) * scale).rounded()),
                scale)
    }()

    static var width: Int { metrics.width }
    static var longestEdge: Int { metrics.longest }
    static var scale: CGFloat { metrics.scale }
}

// MARK: - Renditions

/// How large a decode of a given file is allowed to be. The tag is baked into the cache key, so a
/// feed card's rendition and the full-screen viewer's rendition of the same photo coexist instead
/// of evicting each other — the card keeps its cheap copy when the viewer closes, and the viewer
/// can still fetch a genuinely larger one when it opens.
struct ImageRendition: Hashable {
    /// Longest edge in pixels the decode may produce. 0 means "no downsampling".
    let maxPixelSize: Int
    /// Distinguishes renditions of the same file in the cache key.
    let tag: String

    /// The original pixels. Never cached — a full-resolution decode is exactly the allocation the
    /// cache exists to avoid holding on to (see `MediaLoader.originalImage`).
    static let original = ImageRendition(maxPixelSize: 0, tag: "orig")
}

@MainActor
extension ImageRendition {
    /// A full-width feed card: never wider than the screen, whatever the sensor produced.
    static var card: ImageRendition { ImageRendition(maxPixelSize: ScreenPixels.width, tag: "card") }

    /// The full-screen viewer, zoomable: the screen's longest edge.
    static var fullScreen: ImageRendition { ImageRendition(maxPixelSize: ScreenPixels.longestEdge, tag: "full") }

    /// A fixed point size — avatars, link-preview thumbs, sticker tiles.
    static func points(_ points: CGFloat) -> ImageRendition {
        let pixels = max(Int((points * ScreenPixels.scale).rounded()), 1)
        return ImageRendition(maxPixelSize: pixels, tag: "p\(pixels)")
    }
}

// MARK: - The cache

/// A decoded-image cache bounded by BYTES first and object count second. Thread-safe (NSCache is),
/// so the decode can insert from whatever thread it finished on.
final class ImageMemoryCache {
    /// Below this a cache stops earning its keep: every scroll re-decodes and the app spends more
    /// on CPU than it saves on memory.
    static let minimumBudget = 16 << 20   // 16 MB
    /// Above this a single image cache is a jetsam risk on its own. 64 MB already holds roughly a
    /// dozen full-width card renditions on a 3× phone (1290 × ~970 × 4 B ≈ 5 MB each).
    static let maximumBudget = 64 << 20   // 64 MB

    private let cache = NSCache<NSString, UIImage>()

    /// Bytes of decoded pixels this cache may hold. `NSCache.totalCostLimit` is advisory — it
    /// evicts *around* the limit rather than guaranteeing it — but it is the eviction signal that
    /// makes bytes bind, and combined with the memory-warning purge in MediaLoader it keeps the
    /// decoded-pixel footprint inside a fraction of the app's jetsam headroom.
    let byteLimit: Int
    let countLimit: Int

    init(byteLimit: Int = ImageMemoryCache.budget(availableBytes: ImageMemoryCache.availableAppMemory()),
         countLimit: Int = 200) {
        self.byteLimit = byteLimit
        self.countLimit = countLimit
        cache.totalCostLimit = byteLimit
        // A count limit is still useful as a second ceiling for pathologically tiny images
        // (avatars are ~46 KB, so bytes alone would let thousands of them accumulate).
        cache.countLimit = countLimit
        cache.name = "tgsocial.decoded-images"
    }

    // MARK: Keys

    static func key(_ uniqueId: String, _ rendition: ImageRendition) -> String {
        "\(uniqueId)#\(rendition.tag)"
    }

    // MARK: Storage

    func image(_ key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    /// Inserts with its real cost in bytes. Returns the cost so callers (and tests) can see it.
    @discardableResult
    func insert(_ image: UIImage, key: String) -> Int {
        let cost = Self.cost(of: image)
        cache.setObject(image, forKey: key as NSString, cost: cost)
        return cost
    }

    func removeAll() { cache.removeAllObjects() }

    // MARK: Cost

    /// The real size of the decoded buffer: `bytesPerRow × height` straight off the CGImage, which
    /// already accounts for row padding and for 8-bit vs. wide-gamut 16-bit components. Point size
    /// is useless here — a 100 pt image at 3× is nine times the pixels of the same at 1×.
    static func cost(of image: UIImage) -> Int {
        if let cg = image.cgImage {
            return max(cg.bytesPerRow * cg.height, 1)
        }
        // No backing CGImage (CIImage-backed, or a symbol): fall back to pixels × 4 bytes.
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        return max(Int(pixels.rounded()) * 4, 1)
    }

    // MARK: Budget

    /// Bytes this process may still allocate before iOS kills it. `os_proc_available_memory()` is
    /// the number the jetsam daemon actually works from, so it already accounts for the device, the
    /// app's current footprint, and whether the app is foreground.
    static func availableAppMemory() -> Int {
        let available = Int(os_proc_available_memory())
        if available > 0 { return available }
        // Simulator, or a platform where the call is not applicable: assume an app may use about a
        // quarter of physical RAM, which is a conservative read of the historical jetsam limits.
        return Int(ProcessInfo.processInfo.physicalMemory / 4)
    }

    /// The derivation, stated once: decoded images are the largest single consumer in this app but
    /// not the only one — TDLib's own buffers, an AVPlayer's decode ring, the SwiftUI view tree and
    /// the feed's post structs all need room, and the headroom has to survive a burst (opening the
    /// viewer decodes a screen-sized rendition on top of everything the feed is holding). One
    /// **eighth** of what is available leaves seven eighths for all of that and for the spike,
    /// which is the same ratio Apple's own downsampling guidance lands on. It is then clamped:
    /// never below `minimumBudget` (a cache smaller than that just thrashes) and never above
    /// `maximumBudget` (past which the cache is itself a jetsam risk).
    ///
    /// On a 6 GB iPhone with ~1.4 GB of headroom this gives 64 MB (the ceiling); on a memory-tight
    /// device reporting 200 MB of headroom it gives 25 MB; on a device already near its limit it
    /// floors at 16 MB and the memory-warning purge does the rest.
    static func budget(availableBytes: Int) -> Int {
        let eighth = availableBytes / 8
        return min(max(eighth, minimumBudget), maximumBudget)
    }
}

// MARK: - Memory pressure

/// Watches `UIApplication.didReceiveMemoryWarningNotification` and runs `onWarning` on the main
/// actor. Its own `deinit` unregisters, and the registration never retains the owner — so an owner
/// that goes away stops being called instead of leaking a live observer.
///
/// Split out of `MediaLoader` so the wiring is testable on its own: `MediaLoader` needs a live
/// TDLib client, and the question "does the app actually observe the warning" should not.
final class MemoryPressureWatch {
    private var token: NSObjectProtocol?

    init(onWarning: @escaping @MainActor () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onWarning() }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

// MARK: - Decoding

enum ImageDecoder {
    /// Decodes `path` so its longest edge is at most `maxPixelSize`, using ImageIO's thumbnail
    /// path: the full-size bitmap is never materialised, so peak memory is the *output* size, not
    /// the sensor size. `kCGImageSourceCreateThumbnailFromImageAlways` ignores any embedded
    /// (small, wrong-aspect) EXIF thumbnail and downsamples the real image;
    /// `…WithTransform` applies the EXIF orientation so the result needs no UIImage rotation;
    /// `…ShouldCacheImmediately` forces the decode here, off the main thread, instead of lazily
    /// during the first draw.
    ///
    /// `maxPixelSize <= 0` means "original pixels" and goes through `UIImage(contentsOfFile:)`,
    /// which handles orientation for us. That path is for saving to the photo library only.
    static func decode(path: String, maxPixelSize: Int) -> UIImage? {
        guard maxPixelSize > 0 else { return UIImage(contentsOfFile: path) }
        let url = URL(fileURLWithPath: path) as CFURL
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url, sourceOptions) else {
            return UIImage(contentsOfFile: path)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            // Formats ImageIO will open but not thumbnail (some animated stickers): fall back
            // rather than showing nothing.
            return UIImage(contentsOfFile: path)
        }
        return UIImage(cgImage: cg)
    }
}
