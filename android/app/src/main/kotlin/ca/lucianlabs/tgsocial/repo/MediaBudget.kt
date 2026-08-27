package ca.lucianlabs.tgsocial.repo

/**
 * How many bytes of decoded pixels this process is allowed to hold, and how far a photo has to be scaled down
 * before it is decoded. Plain Kotlin, no Android imports, so every number here is unit-testable.
 *
 * ### Where the budget comes from
 * `Runtime.getRuntime().maxMemory()` is the Dalvik heap ceiling ART grants this process — the same number
 * `ActivityManager.getMemoryClass()` reports, in bytes (≈96 MB on a low-end phone, 256–512 MB on a recent one).
 * Since API 26 bitmap pixels live in native memory rather than that heap, but they are still charged to the
 * process footprint the low-memory killer scores, so the heap ceiling is the honest proxy for "how much this
 * app may keep resident" — it is the same proxy Glide and Picasso use.
 *
 * We take **1/8 of it** ([IMAGE_FRACTION]): seven eighths stay available for TDLib's own buffers, the Compose
 * scene, ExoPlayer, and the object graph, which is where an image cache that eats the whole heap turns into a
 * jetsam/LMK kill rather than an eviction. The fraction is then clamped:
 *
 * - **floor [MIN_IMAGE_BYTES] = 8 MB** — a full-width feed photo at 1080 px on a 16:9 crop is 1080x608x4 ≈
 *   2.6 MB, so 8 MB still holds three cards; below that the cache thrashes on a single flick.
 * - **ceiling [MAX_IMAGE_BYTES] = 48 MB** — tens of megabytes, per the fix brief. Without it a 512 MB
 *   `largeHeap` device would park 64 MB of pixels it never re-reads, and the eviction that eventually frees
 *   them lands as a stall.
 *
 * Minithumbnails (the blur-up ground, ≤ [MINI_PX] wide, RGB_565) get their own small slice so a scroll through
 * a thousand posts cannot let placeholders crowd out the real pixels.
 */
object MediaBudget {
    const val IMAGE_FRACTION = 8
    const val MIN_IMAGE_BYTES = 8L * 1024 * 1024
    const val MAX_IMAGE_BYTES = 48L * 1024 * 1024

    const val MINI_FRACTION = 64
    const val MIN_MINI_BYTES = 1L * 1024 * 1024
    const val MAX_MINI_BYTES = 4L * 1024 * 1024

    /**
     * Spectrogram strips (PRODUCT §2.11.1) get their own slice of the same heap ceiling, on the same
     * derivation as everything else here. A strip is a bitmap — 480x128 ARGB is 245 KB — so it belongs in
     * this accounting or it is unbounded retained memory the LMK gets to discover for us.
     *
     * A slice rather than a share of [IMAGE_FRACTION] because the two have opposite economics: a photo is
     * re-decoded from a local file in milliseconds, while a strip costs a decode *and* a few thousand FFTs,
     * so letting a fling through a photo-heavy feed evict every strip would buy 8 MB back and pay for it in
     * seconds of re-analysis. 1/64 of the heap, floored at 1 MB (~4 strips, enough for a screenful) and
     * capped at 6 MB (~24), which is more clips than a viewport has ever held.
     */
    const val STRIP_FRACTION = 64
    const val MIN_STRIP_BYTES = 1L * 1024 * 1024
    const val MAX_STRIP_BYTES = 6L * 1024 * 1024
    const val STRIP_COUNT_LIMIT = 64

    /**
     * How many spectrogram analyses may be in flight at once.
     *
     * The *retained* cost of a strip is the 245 KB bitmap above; the *transient* cost is the decoded mono PCM
     * it is computed from, which is far larger and, being a local rather than a cache entry, is the kind of
     * allocation that gets discovered by the low-memory killer instead of by an eviction. At §2.11.1's
     * ten-minute ceiling that transient is [pcmBytes] of `MAX_SAMPLES` = 36.6 MB — already more than a third
     * of a 96 MB heap on its own, so **one at a time**. A feed is very good at asking for six: `Dispatchers.IO`
     * hands out 64 threads, and three visible audio posts on a fling is three decodes with nothing between
     * them and the heap ceiling.
     *
     * Serialising costs latency on the second strip and nothing else — the analysis is a decode plus a few
     * thousand FFTs, and the row is already usable from its silhouette while it waits (§2.11.1: "The row is
     * usable the moment it appears; the spectrum fills in").
     */
    const val STRIP_ANALYSIS_CONCURRENCY = 1

    /** What decoded mono PCM of [samples] costs while an analysis holds it. `FloatArray`, so 4 bytes each. */
    fun pcmBytes(samples: Int): Long = samples.coerceAtLeast(0).toLong() * Float.SIZE_BYTES

    /**
     * The worst case the audio path can have live at once for clips of [samples]: the transient PCM times
     * [STRIP_ANALYSIS_CONCURRENCY]. This is the number that has to stay small next to the heap, and the
     * reason callers size their decode from the clip's duration rather than from the cap.
     */
    fun peakAnalysisBytes(samples: Int): Long = pcmBytes(samples) * STRIP_ANALYSIS_CONCURRENCY

    /** Secondary guard only; bytes bind first. */
    const val IMAGE_COUNT_LIMIT = 160
    const val MINI_COUNT_LIMIT = 512

    /** Widest a minithumbnail is ever decoded — it is a blurred placeholder, never the picture. */
    const val MINI_PX = 128

    /** Decode buckets below the display width: avatars/row thumbs and link-preview/sticker thumbs. */
    const val AVATAR_PX = 96
    const val THUMB_PX = 256

    /** Hard ceiling on any decode's **width**, zoom included. */
    const val MAX_DECODE_PX = 2048

    /**
     * Hard ceiling on any decode's **area** — the one that actually binds the allocation. A width cap alone
     * says nothing about the second dimension: a 1200x20000 long screenshot sent as a document is narrower
     * than [MAX_DECODE_PX], so a width-only target never fires and it decodes at 96 MB in one allocation —
     * more than the whole image budget, and the jetsam class this file exists to close.
     *
     * 2048x2048 = 4 Mpx = 16 MB at ARGB_8888, which is already a third of [MAX_IMAGE_BYTES]; nothing may
     * exceed it, whatever its shape. [fitWidth] is how every decode path applies it.
     */
    const val MAX_DECODE_PIXELS: Long = MAX_DECODE_PX.toLong() * MAX_DECODE_PX

    fun imageCacheBytes(maxMemoryBytes: Long): Long =
        (maxMemoryBytes / IMAGE_FRACTION).coerceIn(MIN_IMAGE_BYTES, MAX_IMAGE_BYTES)

    fun miniCacheBytes(maxMemoryBytes: Long): Long =
        (maxMemoryBytes / MINI_FRACTION).coerceIn(MIN_MINI_BYTES, MAX_MINI_BYTES)

    fun stripCacheBytes(maxMemoryBytes: Long): Long =
        (maxMemoryBytes / STRIP_FRACTION).coerceIn(MIN_STRIP_BYTES, MAX_STRIP_BYTES)

    /** What a decoded bitmap of this size actually costs. ARGB_8888 = 4 bytes/px, RGB_565 = 2. */
    fun bitmapBytes(width: Int, height: Int, bytesPerPixel: Int = 4): Long =
        width.coerceAtLeast(0).toLong() * height.coerceAtLeast(0).toLong() * bytesPerPixel.coerceAtLeast(1)

    /**
     * `BitmapFactory.Options.inSampleSize` for a source of [sourceWidth] rendered at [targetWidth]: the largest
     * power of two that still decodes at or above the target, so nothing is ever decoded at sensor resolution
     * to fill a feed card.
     */
    fun sampleSize(sourceWidth: Int, targetWidth: Int): Int {
        if (sourceWidth <= 0 || targetWidth <= 0) return 1
        var sample = 1
        while (sourceWidth / (sample * 2) >= targetWidth) sample *= 2
        return sample
    }

    /**
     * The decode bucket a request of [targetWidthPx] rounds up to. Requests are quantised so the same photo is
     * decoded once per size class and the cache key ([MediaRepo.key]) stays stable — and so the viewer can still
     * ask for the bigger [zoomPx] rendition of a photo the feed already holds at [cardPx].
     */
    fun bucket(targetWidthPx: Int, cardPx: Int, zoomPx: Int): Int = when {
        targetWidthPx <= AVATAR_PX -> AVATAR_PX
        targetWidthPx <= THUMB_PX -> THUMB_PX
        targetWidthPx <= cardPx -> cardPx
        else -> zoomPx
    }

    /**
     * Full-width card decode width for a column [columnWidthPx] wide.
     *
     * That argument is the width the card is **drawn** at, not the display width. House Pour caps the content
     * column (`HPTokens.Space.columnMax`) and pads it, so on anything wider than the cap — every landscape
     * phone, every tablet — the display is far wider than the picture. Sizing the bucket off the display both
     * wastes pixels and, worse, lets a request that is legitimately card-sized fall past `cardPx` in [bucket]
     * and land in the zoom rendition.
     */
    fun cardPx(columnWidthPx: Int): Int = columnWidthPx.coerceIn(THUMB_PX + 1, MAX_DECODE_PX)

    /** One step up for pinch-zoom in the viewer, which is full-bleed and not column-capped. */
    fun zoomPx(displayWidthPx: Int): Int =
        (displayWidthPx.coerceIn(THUMB_PX + 1, MAX_DECODE_PX) * 2).coerceAtMost(MAX_DECODE_PX)

    /**
     * The width to decode a [sourceWidth]x[sourceHeight] source at so the result is at most [targetWidth] wide
     * **and** at most [maxPixels] in total, aspect preserved. Both truncate down, so the product is never over.
     *
     * Callers clamp [targetWidth] to the source themselves where upscaling is wrong (bitmap decodes) and leave
     * it alone where it is not (a PDF page is vector art rendered at whatever size is asked for).
     */
    fun fitWidth(sourceWidth: Int, sourceHeight: Int, targetWidth: Int, maxPixels: Long = MAX_DECODE_PIXELS): Int {
        val want = targetWidth.coerceAtLeast(1)
        if (sourceWidth <= 0 || sourceHeight <= 0) return want
        if (want.toLong() * heightFor(sourceWidth, sourceHeight, want) <= maxPixels) return want
        val fitted = kotlin.math.sqrt(maxPixels.toDouble() * sourceWidth / sourceHeight).toInt()
        return fitted.coerceIn(1, want)
    }

    /** The height that holds [sourceWidth]:[sourceHeight] at [width]. */
    fun heightFor(sourceWidth: Int, sourceHeight: Int, width: Int): Int =
        if (sourceWidth <= 0) 1 else (sourceHeight.toLong() * width / sourceWidth).toInt().coerceAtLeast(1)
}
