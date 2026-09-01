package ca.lucianlabs.tgsocial.repo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The derivation in [MediaBudget], pinned: a fraction of the runtime's heap ceiling, clamped at both ends. */
class MediaBudgetTest {
    private fun mb(v: Int) = v.toLong() * 1024 * 1024

    @Test
    fun budgetIsAnEighthOfTheHeapCeiling() {
        assertEquals(mb(32), MediaBudget.imageCacheBytes(mb(256)))
        assertEquals(mb(24), MediaBudget.imageCacheBytes(mb(192)))
    }

    @Test
    fun budgetIsClampedAtBothEnds() {
        // A 48 MB-heap device would otherwise get a 6 MB cache that thrashes on a single flick.
        assertEquals(MediaBudget.MIN_IMAGE_BYTES, MediaBudget.imageCacheBytes(mb(48)))
        // A largeHeap tablet would otherwise park 64 MB of pixels it never re-reads.
        assertEquals(MediaBudget.MAX_IMAGE_BYTES, MediaBudget.imageCacheBytes(mb(512)))
        assertEquals(MediaBudget.MAX_IMAGE_BYTES, MediaBudget.imageCacheBytes(mb(4096)))
    }

    @Test
    fun theFloorStillHoldsAWholeScreenOfFeedCards() {
        // A full-width card on a 1080 px display, 16:9, ARGB_8888.
        val card = MediaBudget.bitmapBytes(1080, 608)
        assertTrue("floor must hold at least three cards", MediaBudget.MIN_IMAGE_BYTES / card >= 3)
    }

    @Test
    fun minithumbnailSliceIsSmallAndClamped() {
        assertEquals(mb(4), MediaBudget.miniCacheBytes(mb(256)))
        assertEquals(MediaBudget.MIN_MINI_BYTES, MediaBudget.miniCacheBytes(mb(32)))
        assertTrue(MediaBudget.miniCacheBytes(mb(512)) < MediaBudget.imageCacheBytes(mb(512)))
    }

    @Test
    fun bitmapBytesCountsBytesPerPixel() {
        assertEquals(1080L * 1920 * 4, MediaBudget.bitmapBytes(1080, 1920))
        assertEquals(128L * 128 * 2, MediaBudget.bitmapBytes(128, 128, bytesPerPixel = 2))
        assertEquals(0L, MediaBudget.bitmapBytes(0, 1920))
    }

    @Test
    fun sampleSizeNeverDecodesBelowTheTargetWidth() {
        // A 12 MP photo into a 1080 px card: 4032 / 2 = 2016 ≥ 1080, / 4 = 1008 < 1080 → sample 2.
        assertEquals(2, MediaBudget.sampleSize(sourceWidth = 4032, targetWidth = 1080))
        assertEquals(8, MediaBudget.sampleSize(sourceWidth = 4032, targetWidth = 256))
        assertEquals(32, MediaBudget.sampleSize(sourceWidth = 4032, targetWidth = 96))
        // Already small enough: never upsample.
        assertEquals(1, MediaBudget.sampleSize(sourceWidth = 320, targetWidth = 1080))
        assertEquals(1, MediaBudget.sampleSize(sourceWidth = 0, targetWidth = 1080))
    }

    @Test
    fun downsampledCardDecodeIsASmallSliceOfTheBudget() {
        // The bug, in numbers: a 12 MP phone photo decoded at sensor resolution.
        val full = MediaBudget.bitmapBytes(4032, 3024)
        assertTrue("full-resolution decode is ~48 MB", full > mb(46))

        val target = MediaBudget.cardPx(1080)
        val decoded = MediaBudget.bitmapBytes(target, 3024 * target / 4032)
        assertTrue("card decode is an order of magnitude smaller", decoded * 10 < full)
        assertTrue("even the smallest budget holds two full-width cards", MediaBudget.MIN_IMAGE_BYTES / decoded >= 2)

        // The pre-28 BitmapFactory path only steps in powers of two, so it must land at or above the target
        // and then scale the rest of the way (MediaRepo.scaleDown) rather than below it.
        val sampled = 4032 / MediaBudget.sampleSize(4032, target)
        assertTrue("sampled width never drops below the target", sampled >= target)
    }

    @Test
    fun bucketsQuantiseByRoleAndKeepTheZoomRenditionSeparate() {
        val card = MediaBudget.cardPx(1080)
        val zoom = MediaBudget.zoomPx(1080)
        assertEquals(1080, card)
        assertEquals(2048, zoom)
        assertEquals(MediaBudget.AVATAR_PX, MediaBudget.bucket(64, card, zoom))
        assertEquals(MediaBudget.THUMB_PX, MediaBudget.bucket(200, card, zoom))
        assertEquals(card, MediaBudget.bucket(1000, card, zoom))
        assertEquals(zoom, MediaBudget.bucket(9999, card, zoom))
    }

    /**
     * PRODUCT §2.11.3 — a mosaic tile is a thumbnail. The naive mosaic asks for the card width four times over
     * and decodes four pictures at four times the area each is drawn at; on a small device that is more bytes
     * for one post than the whole image budget holds.
     */
    @Test
    fun aMosaicTileCostsATileRatherThanACard() {
        val column = 1080
        val card = MediaBudget.cardPx(column)
        val tile = MediaBudget.mosaicTilePx(column)
        assertEquals("a tile is half the column — every mosaic is two columns wide", card / 2, tile)

        val cardBytes = MediaBudget.bitmapBytes(card, card)
        val tileBytes = MediaBudget.bitmapBytes(tile, tile)
        assertEquals("a tile is a quarter of the pixels", 4L, cardBytes / tileBytes)
        assertTrue(
            "four tiles cost less than two cards, where the naive mosaic costs four",
            tileBytes * 4 < cardBytes * 2,
        )
        assertTrue("and a whole 4-photo mosaic fits the smallest budget", tileBytes * 4 < MediaBudget.MIN_IMAGE_BYTES)

        // It follows the column like the card bucket does, and never falls below the thumb class.
        assertTrue(MediaBudget.mosaicTilePx(2400) > MediaBudget.mosaicTilePx(720))
        assertTrue(MediaBudget.mosaicTilePx(320) > MediaBudget.AVATAR_PX)
        assertTrue("and never past the hard ceiling", MediaBudget.mosaicTilePx(8192) <= MediaBudget.MAX_DECODE_PX)
    }

    @Test
    fun noDecodeIsEverAllowedPastTheHardCeiling() {
        // A 4K-wide tablet: the zoom rendition still stops at MAX_DECODE_PX.
        assertEquals(MediaBudget.MAX_DECODE_PX, MediaBudget.zoomPx(2160))
        assertTrue(MediaBudget.cardPx(4096) <= MediaBudget.MAX_DECODE_PX)
    }

    /**
     * The width ceiling says nothing about the second dimension. A long screenshot sent as a *document* is the
     * untouched original: 1200 px wide is under every width bucket, so a width-only target never fires and the
     * thing decodes at 1200x20000x4 = 96 MB — twice the whole image budget, in one allocation.
     */
    @Test
    fun aTallNarrowSourceIsBoundedByAreaNotWidth() {
        val srcW = 1200
        val srcH = 20_000
        assertTrue("the source is narrower than any width bucket", srcW < MediaBudget.MAX_DECODE_PX)
        assertTrue("unbounded, it is 96 MB", MediaBudget.bitmapBytes(srcW, srcH) > mb(90))

        val w = MediaBudget.fitWidth(srcW, srcH, targetWidth = MediaBudget.MAX_DECODE_PX.coerceAtMost(srcW))
        val h = MediaBudget.heightFor(srcW, srcH, w)
        assertTrue("the decode is narrowed even though the width already fit", w < srcW)
        assertTrue("area stays under the hard ceiling", w.toLong() * h <= MediaBudget.MAX_DECODE_PIXELS)
        assertTrue("and so the decode fits the budget", MediaBudget.bitmapBytes(w, h) < MediaBudget.MAX_IMAGE_BYTES)
        // Aspect is preserved to within a pixel of rounding.
        assertEquals(srcH.toDouble() / srcW, h.toDouble() / w, 0.01)
    }

    @Test
    fun fitWidthIsANoOpForOrdinarilyShapedSources() {
        // A 12 MP 4:3 photo into a 1080 px card: 1080x810 = 0.9 Mpx, nowhere near the ceiling.
        assertEquals(1080, MediaBudget.fitWidth(4032, 3024, targetWidth = 1080))
        assertEquals(810, MediaBudget.heightFor(4032, 3024, 1080))
        // A square source at the zoom bucket sits exactly on the ceiling, so it must not be narrowed.
        assertEquals(2048, MediaBudget.fitWidth(4000, 4000, targetWidth = 2048))
        // Degenerate bounds fall back to the request rather than dividing by zero.
        assertEquals(1080, MediaBudget.fitWidth(0, 0, targetWidth = 1080))
    }

    /**
     * The card bucket is derived from the House Pour column, not the display. Sized off the display, a
     * landscape phone (872 dp wide, column capped at 540 dp) asked for 1298 px against a 1080 px bucket and
     * every inline feed photo fell past `cardPx` into the 2048 px zoom rendition — ~4x the bytes it draws.
     */
    @Test
    fun theCardBucketCoversTheColumnTheCardIsDrawnIn() {
        val portraitColumn = 891 // (392dp screen → 324dp column) x 2.75
        val landscapeColumn = 1298 // (capped at 540dp → 472dp column) x 2.75
        val display = 1080

        val wrong = MediaBudget.cardPx(display)
        assertEquals(MediaBudget.zoomPx(display), MediaBudget.bucket(landscapeColumn, wrong, MediaBudget.zoomPx(display)))

        val right = MediaBudget.cardPx(landscapeColumn)
        assertEquals(right, MediaBudget.bucket(landscapeColumn, right, MediaBudget.zoomPx(display)))
        assertEquals(right, MediaBudget.bucket(portraitColumn, right, MediaBudget.zoomPx(display)))
        assertTrue("a card decode never costs a zoom decode", MediaBudget.bitmapBytes(right, right * 9 / 16) < MediaBudget.bitmapBytes(2048, 2048 * 9 / 16))
    }
}
