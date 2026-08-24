// Unit tests — the memory bounds behind the jetsam fix: image-cache cost accounting, the cache
// budget derivation, and the bounded feed window.

import UIKit
import XCTest
@testable import tgsocial

// MARK: - Image cache cost accounting

final class ImageCacheCostTests: XCTestCase {
    /// A real decoded bitmap at 1× so pixel count and point size line up in the assertions.
    private func opaqueImage(width: Int, height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    func testCostIsTheRealDecodedBufferSize() throws {
        let image = opaqueImage(width: 200, height: 100)
        let cg = try XCTUnwrap(image.cgImage)
        // The contract: cost is bytesPerRow × height, straight off the CGImage.
        XCTAssertEqual(ImageMemoryCache.cost(of: image), cg.bytesPerRow * cg.height)
        // And that is at least four bytes per pixel — never the point size, never a constant.
        XCTAssertGreaterThanOrEqual(ImageMemoryCache.cost(of: image), 200 * 100 * 4)
    }

    func testCostGrowsWithPixelsNotWithObjectCount() {
        let small = ImageMemoryCache.cost(of: opaqueImage(width: 100, height: 100))
        let large = ImageMemoryCache.cost(of: opaqueImage(width: 1000, height: 1000))
        // This is the whole bug in one assertion: an object-count limit treats these as equal,
        // while they differ by two orders of magnitude in bytes.
        XCTAssertGreaterThan(large, small * 50)
    }

    func testCostIsNeverZero() {
        XCTAssertGreaterThan(ImageMemoryCache.cost(of: opaqueImage(width: 1, height: 1)), 0)
        XCTAssertGreaterThan(ImageMemoryCache.cost(of: UIImage()), 0)
    }

    func testInsertReportsTheSameCostItCharges() {
        let cache = ImageMemoryCache(byteLimit: 8 << 20, countLimit: 32)
        let image = opaqueImage(width: 320, height: 240)
        XCTAssertEqual(cache.insert(image, key: "k"), ImageMemoryCache.cost(of: image))
        XCTAssertNotNil(cache.image("k"))
    }

    func testCacheIsBoundedByBytesAndByCount() {
        let cache = ImageMemoryCache(byteLimit: 4 << 20, countLimit: 12)
        XCTAssertEqual(cache.byteLimit, 4 << 20)
        XCTAssertEqual(cache.countLimit, 12)
    }

    func testPurgeEmptiesTheCache() {
        let cache = ImageMemoryCache(byteLimit: 8 << 20, countLimit: 32)
        cache.insert(opaqueImage(width: 64, height: 64), key: "a")
        cache.insert(opaqueImage(width: 64, height: 64), key: "b")
        cache.removeAll()
        XCTAssertNil(cache.image("a"))
        XCTAssertNil(cache.image("b"))
    }

    @MainActor
    func testRenditionsOfOneFileGetSeparateKeys() {
        let id = "photo-unique-id"
        let card = ImageMemoryCache.key(id, .card)
        let full = ImageMemoryCache.key(id, .fullScreen)
        let avatar = ImageMemoryCache.key(id, .points(36))
        XCTAssertNotEqual(card, full, "the viewer must not evict the card's cheaper rendition")
        XCTAssertNotEqual(card, avatar)
        XCTAssertNotEqual(full, avatar)
        XCTAssertEqual(card, ImageMemoryCache.key(id, .card))
    }

    @MainActor
    func testRenditionsAreSizedInPixelsAndOrdered() {
        XCTAssertGreaterThan(ImageRendition.card.maxPixelSize, ImageRendition.points(36).maxPixelSize)
        XCTAssertGreaterThanOrEqual(ImageRendition.fullScreen.maxPixelSize, ImageRendition.card.maxPixelSize)
        // A 36 pt avatar on a 2×/3× screen is 72–108 px — not 36, and nowhere near a sensor image.
        XCTAssertGreaterThanOrEqual(ImageRendition.points(36).maxPixelSize, 36)
        XCTAssertLessThan(ImageRendition.points(36).maxPixelSize, 256)
        // `original` is the only rendition that means "no downsampling".
        XCTAssertEqual(ImageRendition.original.maxPixelSize, 0)
    }
}

// MARK: - Cache budget derivation

final class ImageCacheBudgetTests: XCTestCase {
    func testBudgetIsOneEighthOfAvailableMemory() {
        // 400 MB of headroom → 50 MB, between the floor and the ceiling.
        XCTAssertEqual(ImageMemoryCache.budget(availableBytes: 400 << 20), 50 << 20)
    }

    func testBudgetFloorsSoTheCacheStillEarnsItsKeep() {
        XCTAssertEqual(ImageMemoryCache.budget(availableBytes: 8 << 20), ImageMemoryCache.minimumBudget)
        XCTAssertEqual(ImageMemoryCache.budget(availableBytes: 0), ImageMemoryCache.minimumBudget)
    }

    func testBudgetCeilingsSoTheCacheIsNotItselfAJetsamRisk() {
        XCTAssertEqual(ImageMemoryCache.budget(availableBytes: 4 << 30), ImageMemoryCache.maximumBudget)
    }

    func testBudgetIsMonotonicAndAlwaysInsideItsBounds() {
        var previous = 0
        for megabytes in stride(from: 16, through: 2048, by: 16) {
            let budget = ImageMemoryCache.budget(availableBytes: megabytes << 20)
            XCTAssertGreaterThanOrEqual(budget, ImageMemoryCache.minimumBudget)
            XCTAssertLessThanOrEqual(budget, ImageMemoryCache.maximumBudget)
            XCTAssertGreaterThanOrEqual(budget, previous)
            previous = budget
        }
    }

    func testRuntimeBudgetIsUsable() {
        // Whatever the device reports, the derived budget has to land inside the clamp.
        let budget = ImageMemoryCache.budget(availableBytes: ImageMemoryCache.availableAppMemory())
        XCTAssertGreaterThanOrEqual(budget, ImageMemoryCache.minimumBudget)
        XCTAssertLessThanOrEqual(budget, ImageMemoryCache.maximumBudget)
        XCTAssertGreaterThan(ImageMemoryCache.availableAppMemory(), 0)
    }
}

// MARK: - The bounded feed window

final class FeedWindowTests: XCTestCase {
    private struct Item: FeedEntry, Equatable {
        let sourceKey: String
        let messageId: Int64
        let date: Int
    }

    /// `count` posts newest-first, ids counting down from `newestId`.
    private func page(newestId: Int64, count: Int, source: String = "a") -> [Item] {
        (0..<count).map { i in
            let id = newestId - Int64(i)
            return Item(sourceKey: source, messageId: id, date: Int(id) * 10)
        }
    }

    func testAListInsideTheLimitIsUntouched() {
        let items = page(newestId: 100, count: 100)
        XCTAssertEqual(FeedWindow.trimmed(items, limit: 300), items)
        XCTAssertEqual(FeedWindow.overflow(items.count, limit: 300), 0)
    }

    func testTheWindowIsBoundedAndStaysNewestFirst() {
        let items = page(newestId: 1000, count: 1000)
        let window = FeedWindow.trimmed(items, limit: 300)
        XCTAssertEqual(window.count, 300)
        XCTAssertTrue(FeedOrder.isNewestFirst(window))
    }

    func testTrimEvictsTheHeadNotTheMostRecentlyLoadedPage() {
        // An oversized list handed to a rebuild: a full window plus a page of older entries.
        let window = page(newestId: 1000, count: 300)
        let olderPage = page(newestId: 700, count: 30)
        let trimmed = FeedWindow.trimmed(window + olderPage, limit: 300)

        XCTAssertEqual(trimmed.count, 300)
        // The most recently loaded entries survive — trimming the tail instead would have deleted
        // exactly this page and dead-ended pagination at the cap.
        for item in olderPage {
            XCTAssertTrue(trimmed.contains(item), "the newly loaded page must survive the trim")
        }
        // What left is the front: the oldest-loaded, newest-dated entries.
        XCTAssertEqual(trimmed.first?.messageId, 970)
        XCTAssertEqual(trimmed.last?.messageId, 671)
        XCTAssertTrue(FeedOrder.isNewestFirst(trimmed))
    }

    func testATrimShiftsEveryEntryTheReaderIsBelowIt() {
        // Why `loadMore` must never call this: dropping entries from the front moves every survivor
        // down by exactly `overflow` positions. The feed is a ScrollView + LazyVStack with no scroll
        // anchoring, so a viewport pinned to an offset — not to an id — ends up `overflow` cards
        // deeper into the feed. And because "Load more" only ever fires near the tail, that lands
        // the viewport at the tail again and pages until the feed is exhausted.
        let window = page(newestId: 1000, count: 330)
        // Where the prefetch trigger sits when the trim would have run: count - prefetchDistance.
        let readerIndex = 330 - 6
        let anchor = window[readerIndex]
        let overflow = FeedWindow.overflow(window.count, limit: 300)
        let trimmed = FeedWindow.trimmed(window, limit: 300)

        XCTAssertEqual(overflow, 30)
        // The post the reader was looking at is still in the window — 30 rows higher than it was.
        XCTAssertEqual(trimmed.firstIndex(of: anchor), readerIndex - overflow)
        // And the row that now sits at the offset the reader was holding is past the end of the
        // shortened list entirely: the footer, whose onAppear calls "Load more" again.
        XCTAssertGreaterThanOrEqual(readerIndex, trimmed.count)
    }

    @MainActor
    func testARebuiltWindowStillOpensOnTheNewestEntries() {
        // The cap is only ever applied where the list is rebuilt from the top, and a rebuilt list is
        // shorter than the cap — so the front of the window is the newest post and the disk cache,
        // which is the front of that window, opens the feed at the top on a cold start.
        let rebuilt = FeedWindow.trimmed(page(newestId: 1000, count: FeedRepository.drainSize))
        XCTAssertEqual(rebuilt.count, FeedRepository.drainSize)
        XCTAssertEqual(rebuilt.first?.messageId, 1000)
        XCTAssertLessThan(FeedWindow.cacheSize, FeedWindow.maxPosts)
    }

    func testOverflowCountsWhatHasToLeaveTheFront() {
        XCTAssertEqual(FeedWindow.overflow(330, limit: 300), 30)
        XCTAssertEqual(FeedWindow.overflow(300, limit: 300), 0)
        XCTAssertEqual(FeedWindow.overflow(12, limit: 300), 0)
    }

    @MainActor
    func testTheDefaultCapIsABackstopNotAScrollTimeCollector() {
        XCTAssertEqual(FeedWindow.maxPosts, 1000)
        XCTAssertEqual(FeedWindow.trimmed(page(newestId: 5000, count: 5000)).count, FeedWindow.maxPosts)
        // Dozens of pages deep: a rebuild reaches it only pathologically, and ordinary reading —
        // which never trims at all now — cannot reach it by paging.
        XCTAssertGreaterThan(FeedWindow.maxPosts, 20 * FeedRepository.pageSize)
    }
}

// MARK: - Downsampling decode

final class ImageDecoderTests: XCTestCase {
    /// Stands in for a photo straight off a phone camera: far more pixels than any feed card can show.
    private func writeLargeJPEG(width: Int, height: Int) throws -> String {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tgsocial-test-\(UUID().uuidString).jpg").path
        try data.write(to: URL(fileURLWithPath: path))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    func testDecodeDownsamplesToTheRequestedLongestEdge() throws {
        let path = try writeLargeJPEG(width: 2400, height: 1600)
        let thumb = try XCTUnwrap(ImageDecoder.decode(path: path, maxPixelSize: 300))
        let cg = try XCTUnwrap(thumb.cgImage)
        XCTAssertLessThanOrEqual(max(cg.width, cg.height), 300)
        // Aspect ratio survives the downsample.
        XCTAssertEqual(Double(cg.width) / Double(cg.height), 2400.0 / 1600.0, accuracy: 0.02)
    }

    func testDownsampledDecodeCostsOrdersOfMagnitudeLessThanTheOriginal() throws {
        let path = try writeLargeJPEG(width: 2400, height: 1600)
        let original = try XCTUnwrap(ImageDecoder.decode(path: path, maxPixelSize: 0))
        let card = try XCTUnwrap(ImageDecoder.decode(path: path, maxPixelSize: 300))
        let originalCost = ImageMemoryCache.cost(of: original)
        let cardCost = ImageMemoryCache.cost(of: card)
        XCTAssertGreaterThan(originalCost, 2400 * 1600 * 3)
        // This is the fix in one number: what the feed retains per photo drops ~30×.
        XCTAssertLessThan(cardCost * 20, originalCost)
    }

    func testAWholeFeedOfDownsampledCardsFitsInTheBudget() throws {
        // 60 cards at card size must not, on their own, exceed the smallest budget we ever hand out.
        let path = try writeLargeJPEG(width: 2400, height: 1600)
        let card = try XCTUnwrap(ImageDecoder.decode(path: path, maxPixelSize: 300))
        XCTAssertLessThan(ImageMemoryCache.cost(of: card) * 60, ImageMemoryCache.minimumBudget)
    }

    func testDecodeOfAMissingFileFailsQuietly() {
        XCTAssertNil(ImageDecoder.decode(path: "/nonexistent/nope.jpg", maxPixelSize: 300))
        XCTAssertNil(ImageDecoder.decode(path: "/nonexistent/nope.jpg", maxPixelSize: 0))
    }
}

// MARK: - Memory-pressure eviction

/// The wiring MediaLoader uses, exercised without a TDLib client behind it.
@MainActor
final class MemoryPressureWatchTests: XCTestCase {
    private func swatch() -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128), format: format)
            .image { ctx in
                UIColor.systemPink.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            }
    }

    private func fireMemoryWarning() async {
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        // The observer is delivered on the main queue; give the run loop a turn.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
    }

    func testAMemoryWarningDropsEveryDecodedImageAndTheCacheStillWorks() async {
        let cache = ImageMemoryCache(byteLimit: 8 << 20, countLimit: 64)
        var purges = 0
        let watch = MemoryPressureWatch { purges += 1; cache.removeAll() }

        cache.insert(swatch(), key: ImageMemoryCache.key("a", .card))
        cache.insert(swatch(), key: ImageMemoryCache.key("b", .fullScreen))
        XCTAssertNotNil(cache.image(ImageMemoryCache.key("a", .card)))

        await fireMemoryWarning()

        XCTAssertEqual(purges, 1, "the memory warning must reach the handler")
        XCTAssertNil(cache.image(ImageMemoryCache.key("a", .card)))
        XCTAssertNil(cache.image(ImageMemoryCache.key("b", .fullScreen)))

        // Survives and repaints: the cache is still usable, so a card scrolled back into view
        // re-decodes and re-caches rather than staying blank.
        cache.insert(swatch(), key: ImageMemoryCache.key("a", .card))
        XCTAssertNotNil(cache.image(ImageMemoryCache.key("a", .card)))
        withExtendedLifetime(watch) {}
    }

    func testTheWatchStopsFiringOnceItIsReleased() async {
        var purges = 0
        var watch: MemoryPressureWatch? = MemoryPressureWatch { purges += 1 }
        await fireMemoryWarning()
        XCTAssertEqual(purges, 1)

        watch = nil
        await fireMemoryWarning()
        XCTAssertEqual(purges, 1, "a released watch must have unregistered its observer")
        XCTAssertNil(watch)
    }
}
