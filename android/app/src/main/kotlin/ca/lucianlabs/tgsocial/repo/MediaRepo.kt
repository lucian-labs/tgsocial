package ca.lucianlabs.tgsocial.repo

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.ImageBitmapConfig
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.core.content.FileProvider
import ca.lucianlabs.tgsocial.model.FileRef
import ca.lucianlabs.tgsocial.td.TelegramClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.util.Locale

/** Live download state for one TDLib file id, fed by the file updates Flow. */
data class FileState(
    val id: Int,
    val downloaded: Long = 0,
    val size: Long = 0,
    val path: String? = null,
    val active: Boolean = false,
) {
    val progress: Float get() = if (size > 0) (downloaded.toFloat() / size).coerceIn(0f, 1f) else 0f
    val done: Boolean get() = path != null
}

/**
 * PROTOCOL §4.10 / PRODUCT §2.11 — download via TDLib (priority 1 when visible, 32 when tapped), decode at display
 * size, cache by `remote.uniqueId`, expose determinate progress, Save to MediaStore, Share via FileProvider.
 */
class MediaRepo(
    private val tg: TelegramClient,
    private val activity: ActivityRegistry,
    columnWidthPx: Int = 1080,
    displayWidthPx: Int = columnWidthPx,
    maxMemoryBytes: Long = Runtime.getRuntime().maxMemory(),
) {
    companion object {
        const val PRIORITY_VISIBLE = 1
        const val PRIORITY_TAPPED = 32

        /** Live download states are cheap but unbounded over a long scroll — keep the newest this many. */
        const val FILE_STATE_CAP = 512
    }

    /**
     * Full-width feed card decode width, and the one-step-up rendition the viewer may ask for.
     *
     * `cardWidthPx` comes from the **column** the card is drawn in, not the display (see [MediaBudget.cardPx]),
     * and both are `var` because MainActivity declares `configChanges="orientation|screenSize|screenLayout"` —
     * the activity is never recreated on rotation, so nothing else would ever recompute them. Frozen at
     * `Application.onCreate` they described portrait forever, and in landscape every inline photo asked for a
     * width above the stale `cardWidthPx` and fell through [MediaBudget.bucket] into the 2048 px zoom bucket.
     * `TgApp.onConfigurationChanged` feeds the new geometry to [onDisplayChanged].
     */
    var cardWidthPx: Int = MediaBudget.cardPx(columnWidthPx)
        private set
    var zoomWidthPx: Int = MediaBudget.zoomPx(displayWidthPx)
        private set

    /**
     * New display geometry (rotation, multi-window resize, a folding device unfolding). Buckets keyed at the
     * old widths stay in the cache and age out through the LRU — they are still valid pixels for the
     * orientation they were decoded for, and evicting them would re-decode everything on every rotation.
     */
    fun onDisplayChanged(columnWidthPx: Int, displayWidthPx: Int) {
        cardWidthPx = MediaBudget.cardPx(columnWidthPx)
        zoomWidthPx = MediaBudget.zoomPx(displayWidthPx)
    }

    /**
     * Decoded pixels, bounded by BYTES first (see [MediaBudget] for the derivation) and by count second. Every
     * insert reports the bitmap's real `allocationByteCount`, so one 12 MP photo costs what it actually costs
     * instead of counting as "one entry".
     */
    private val images = ByteLruCache<String, ImageBitmap>(
        maxBytes = MediaBudget.imageCacheBytes(maxMemoryBytes),
        maxCount = MediaBudget.IMAGE_COUNT_LIMIT,
        sizeOf = { _, image -> costOf(image) },
    )
    private val minis = ByteLruCache<String, ImageBitmap>(
        maxBytes = MediaBudget.miniCacheBytes(maxMemoryBytes),
        maxCount = MediaBudget.MINI_COUNT_LIMIT,
        sizeOf = { _, image -> costOf(image) },
    )

    /** One in-flight decode per cache key. Refcounted so a finished (or cancelled) load does not leave the
     *  entry behind — an un-pruned map here is a slow leak keyed by every photo ever scrolled past. */
    private class LoadLock {
        val mutex = Mutex()
        var waiters = 0
    }

    private val locks = HashMap<String, LoadLock>()

    private val _files = MutableStateFlow<Map<Int, FileState>>(emptyMap())
    val files: StateFlow<Map<Int, FileState>> = _files.asStateFlow()

    init {
        tg.scope.launch {
            tg.files.collect { f -> record(f.id, f.state()) }
        }
    }

    private fun dev.g000sha256.tdl.dto.File.state() = FileState(
        id = id,
        downloaded = local.downloadedSize,
        size = if (size > 0) size else expectedSize,
        path = local.path.takeIf { local.isDownloadingCompleted && it.isNotEmpty() },
        active = local.isDownloadingActive,
    )

    fun state(ref: FileRef): FileState? = _files.value[ref.id]

    /**
     * Record one file's state, keeping the map bounded. Insertion order is preserved by `Map.plus`, so the
     * entries dropped first are the oldest completed ones; anything still downloading is never dropped (losing
     * it would blank the progress ring mid-transfer).
     */
    private fun record(id: Int, state: FileState) {
        _files.update { current ->
            val next = current + (id to state)
            if (next.size <= FILE_STATE_CAP) return@update next
            var toDrop = next.size - FILE_STATE_CAP
            next.filterTo(LinkedHashMap()) { (key, value) ->
                if (toDrop > 0 && key != id && !value.active) {
                    toDrop--
                    false
                } else {
                    true
                }
            }
        }
    }

    /** The local path when the file is already complete on disk, else null. */
    suspend fun localPath(ref: FileRef): String? {
        ref.localPath?.takeIf { File(it).exists() }?.let { return it }
        state(ref)?.path?.takeIf { File(it).exists() }?.let { return it }
        val f = tg.callOrNull(10_000L) { getFile(fileId = ref.id) } ?: return null
        record(f.id, f.state())
        return f.state().path
    }

    /**
     * Starts (or re-prioritises) a download and waits for completion. The registry entry names the operation
     * (`Downloading photo`) and auto-clears after 30 s even though a large file keeps downloading — progress
     * stays visible on the media itself.
     */
    suspend fun download(ref: FileRef, priority: Int = PRIORITY_VISIBLE, label: String = "Downloading file", timeoutMs: Long = 300_000L): String? {
        localPath(ref)?.let { return it }
        return activity.track(label) {
            val started = tg.callOrNull { downloadFile(fileId = ref.id, priority = priority, offset = 0L, limit = 0L, synchronous = false) }
            if (started != null) record(started.id, started.state())
            if (started?.state()?.done == true) return@track started.state().path
            withTimeoutOrNull(timeoutMs) {
                files.first { it[ref.id]?.done == true }
            }?.get(ref.id)?.path
        }
    }

    /** Fire-and-forget start so progress renders; completion is observed through [files]. */
    fun start(ref: FileRef, priority: Int = PRIORITY_VISIBLE) {
        tg.scope.launch {
            val f = tg.callOrNull { downloadFile(fileId = ref.id, priority = priority, offset = 0L, limit = 0L, synchronous = false) }
            if (f != null) record(f.id, f.state())
        }
    }

    fun cancel(ref: FileRef) {
        tg.scope.launch {
            tg.callOrNull { cancelDownloadFile(fileId = ref.id, onlyIfPending = false) }
            record(ref.id, state(ref)?.copy(active = false) ?: FileState(ref.id))
        }
    }

    fun cached(ref: FileRef, targetWidthPx: Int): ImageBitmap? = images[key(ref, targetWidthPx)]

    /**
     * Cache key = TDLib's stable `uniqueId` plus the decode bucket, so the feed's card-width rendition and the
     * viewer's zoom rendition of the same photo are separate entries and asking for the bigger one later never
     * has to re-download.
     */
    private fun key(ref: FileRef, w: Int) = "${ref.uniqueId}@${bucket(w)}"

    /**
     * [MediaBudget.bucket] with one refinement: only a request that actually asks for [zoomWidthPx] — the
     * viewer, which passes it by value — may reach the zoom bucket. Anything landing between the two is a feed
     * card in a column slightly wider than the geometry we last recorded (a multi-window resize, a
     * configuration change not delivered yet), and rounding that up to 2048 px costs about four times the
     * bytes the card draws, under a second cache key, for pixels nobody ever sees.
     */
    private fun bucket(w: Int): Int =
        if (w > cardWidthPx && w < zoomWidthPx) cardWidthPx else MediaBudget.bucket(w, cardWidthPx, zoomWidthPx)

    suspend fun image(ref: FileRef, targetWidthPx: Int, priority: Int = PRIORITY_VISIBLE): ImageBitmap? {
        val k = key(ref, targetWidthPx)
        images[k]?.let { return it }
        val lock = acquire(k)
        try {
            return lock.withLock {
                images[k]?.let { return@withLock it }
                val path = localPath(ref) ?: download(ref, priority, "Downloading photo") ?: return@withLock null
                val bmp = withContext(Dispatchers.IO) { decode(path, bucket(targetWidthPx)) } ?: return@withLock null
                bmp.also { images.put(k, it) }
            }
        } finally {
            release(k)
        }
    }

    private fun acquire(k: String): Mutex = synchronized(locks) {
        locks.getOrPut(k) { LoadLock() }.also { it.waiters++ }.mutex
    }

    private fun release(k: String) = synchronized(locks) {
        val entry = locks[k] ?: return@synchronized
        entry.waiters--
        if (entry.waiters <= 0) locks.remove(k)
    }

    /**
     * Minithumbnail (base64 JPEG) decoded for the blur-up placeholder — bounded to [MediaBudget.MINI_PX] and
     * RGB_565 (it is only ever drawn blurred, so alpha and the extra two bytes per pixel buy nothing).
     */
    fun mini(b64: String?): ImageBitmap? {
        if (b64.isNullOrBlank()) return null
        minis[b64]?.let { return it }
        return runCatching {
            val bytes = java.util.Base64.getDecoder().decode(b64)
            decodeBounded(bytes, MediaBudget.MINI_PX, Bitmap.Config.RGB_565)?.asImageBitmap()
        }.getOrNull()?.also { minis.put(b64, it) }
    }

    private fun decodeBounded(bytes: ByteArray, targetWidth: Int, config: Bitmap.Config): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0) return null
        val opts = BitmapFactory.Options().apply {
            inSampleSize = MediaBudget.sampleSize(bounds.outWidth, fit(bounds.outWidth, bounds.outHeight, targetWidth))
            inPreferredConfig = config
        }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
    }

    /**
     * The width to actually decode a [w]x[h] source at for a [targetWidth] request: never above the source
     * (upsampling a photo to fill a card buys nothing but bytes) and never past
     * [MediaBudget.MAX_DECODE_PIXELS], which is what bounds the tall-and-narrow case the width alone misses.
     */
    private fun fit(w: Int, h: Int, targetWidth: Int): Int =
        MediaBudget.fitWidth(w, h, targetWidth.coerceAtMost(w.coerceAtLeast(1)))

    /** What one decoded image actually costs: the real buffer where the platform will tell us, else w x h x bpp. */
    private fun costOf(image: ImageBitmap): Long =
        runCatching { image.asAndroidBitmap().allocationByteCount.toLong() }
            .getOrElse { MediaBudget.bitmapBytes(image.width, image.height, bytesPerPixel(image)) }

    private fun bytesPerPixel(image: ImageBitmap): Int = when (image.config) {
        ImageBitmapConfig.Alpha8 -> 1
        ImageBitmapConfig.Rgb565 -> 2
        ImageBitmapConfig.F16 -> 8
        else -> 4
    }

    /**
     * Decode off the main thread; ImageDecoder on 28+ (webp and friends), BitmapFactory before.
     *
     * Both paths size through [fit] rather than comparing the source width to [targetWidth]. A source narrower
     * than the target used to skip resizing entirely on either path, so a long screenshot sent as a document —
     * 1200 px wide, 20 000 tall — decoded at native size: 96 MB in one allocation, which the byte cache then
     * correctly refused to keep, after the allocation had already happened.
     */
    private fun decode(path: String, targetWidth: Int): ImageBitmap? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            return runCatching {
                val source = ImageDecoder.createSource(File(path))
                ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                    decoder.isMutableRequired = false
                    val w = info.size.width
                    val h = info.size.height
                    val target = fit(w, h, targetWidth)
                    if (target < w) decoder.setTargetSize(target, MediaBudget.heightFor(w, h, target))
                }.asImageBitmap()
            }.getOrNull() ?: decodeLegacy(path, targetWidth)
        }
        return decodeLegacy(path, targetWidth)
    }

    private fun decodeLegacy(path: String, targetWidth: Int): ImageBitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0) return null
        val target = fit(bounds.outWidth, bounds.outHeight, targetWidth)
        val opts = BitmapFactory.Options().apply {
            inSampleSize = MediaBudget.sampleSize(bounds.outWidth, target)
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val decoded = BitmapFactory.decodeFile(path, opts) ?: return null
        return scaleDown(decoded, target).asImageBitmap()
    }

    /**
     * `inSampleSize` only steps in powers of two, so a 4032 px original for a 1080 px card lands at 2016 px —
     * 3.5x the pixels the card draws. Finish the job exactly and recycle the intermediate, so what stays
     * resident is what is actually on screen.
     */
    private fun scaleDown(bitmap: Bitmap, targetWidth: Int): Bitmap {
        if (bitmap.width <= targetWidth) return bitmap
        val height = (bitmap.height.toLong() * targetWidth / bitmap.width).toInt().coerceAtLeast(1)
        val scaled = runCatching { Bitmap.createScaledBitmap(bitmap, targetWidth, height, true) }.getOrNull() ?: return bitmap
        if (scaled !== bitmap) bitmap.recycle()
        return scaled
    }

    // ------------------------------------------------------------------ save / share / documents

    /** PRODUCT §2.11 `Save`: MediaStore on 29+ (no permission), public directories on 26–28 (permission asked at tap). */
    suspend fun save(context: Context, path: String, mimeType: String, displayName: String): Boolean = withContext(Dispatchers.IO) {
        runCatching {
            val src = File(path)
            val name = displayName.ifBlank { src.name }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val (collection, dirColumn) = when {
                    mimeType.startsWith("image/") -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI to Environment.DIRECTORY_PICTURES
                    mimeType.startsWith("video/") -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI to Environment.DIRECTORY_MOVIES
                    mimeType.startsWith("audio/") -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI to Environment.DIRECTORY_MUSIC
                    else -> MediaStore.Downloads.EXTERNAL_CONTENT_URI to Environment.DIRECTORY_DOWNLOADS
                }
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, mimeType.ifBlank { "application/octet-stream" })
                    put(MediaStore.MediaColumns.RELATIVE_PATH, "$dirColumn/tgsocial")
                }
                val uri = context.contentResolver.insert(collection, values) ?: return@runCatching false
                context.contentResolver.openOutputStream(uri)?.use { out -> src.inputStream().use { it.copyTo(out) } } ?: return@runCatching false
                true
            } else {
                val dir = when {
                    mimeType.startsWith("image/") -> Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
                    mimeType.startsWith("video/") -> Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES)
                    mimeType.startsWith("audio/") -> Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC)
                    else -> Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                }
                val target = File(File(dir, "tgsocial").apply { mkdirs() }, name)
                src.inputStream().use { input -> target.outputStream().use { input.copyTo(it) } }
                true
            }
        }.getOrDefault(false)
    }

    /** PRODUCT §2.11 `Share`: hand the TDLib-managed file out through the FileProvider. */
    fun share(context: Context, path: String, mimeType: String) {
        runCatching {
            val uri: Uri = FileProvider.getUriForFile(context, "${context.packageName}.files", File(path))
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = mimeType.ifBlank { "application/octet-stream" }
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(Intent.createChooser(intent, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    /** Text documents: the first [limit] bytes as text for the in-app viewer. */
    suspend fun readText(path: String, limit: Int = 512 * 1024): String? = withContext(Dispatchers.IO) {
        runCatching {
            File(path).inputStream().use { input ->
                val buffer = ByteArray(limit)
                var read = 0
                while (read < limit) {
                    val n = input.read(buffer, read, limit - read)
                    if (n < 0) break
                    read += n
                }
                String(buffer, 0, read, Charsets.UTF_8)
            }
        }.getOrNull()
    }

    // PdfRenderer is single-threaded per document; one shared gate is enough for page-at-a-time rendering.
    private val pdfLock = Mutex()

    suspend fun pdfPageCount(path: String): Int = pdfLock.withLock {
        withContext(Dispatchers.IO) {
            runCatching {
                ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
                    PdfRenderer(fd).use { it.pageCount }
                }
            }.getOrDefault(0)
        }
    }

    suspend fun pdfPage(path: String, index: Int, widthPx: Int): ImageBitmap? = pdfLock.withLock {
        withContext(Dispatchers.IO) {
            runCatching {
                ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
                    PdfRenderer(fd).use { renderer ->
                        renderer.openPage(index).use { page ->
                            // A page is vector art, so rendering above its point size is fine — but the aspect
                            // is not bounded either (a one-page banner, a stitched receipt), and h was derived
                            // from it with no ceiling at all. Area-bound it like every other decode.
                            val w = MediaBudget.fitWidth(page.width, page.height, widthPx.coerceAtLeast(1))
                            val h = MediaBudget.heightFor(page.width, page.height, w)
                            val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                            bmp.eraseColor(android.graphics.Color.WHITE)
                            page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            bmp.asImageBitmap()
                        }
                    }
                }
            }.getOrNull()
        }
    }

    // ------------------------------------------------------------------ memory pressure

    /**
     * `ComponentCallbacks2.onTrimMemory` (see `TgApp`): shed decoded pixels down to [fraction] of the budget.
     * Download state is deliberately kept — a composable still on screen holds its own reference to the
     * `ImageBitmap` it is drawing, so eviction never blanks what is visible; scrolled-away cards simply decode
     * again from the file TDLib already has on disk.
     */
    fun trimMemory(fraction: Float) {
        images.trimToBytes((images.maxBytes * fraction.coerceIn(0f, 1f)).toLong())
        minis.trimToBytes((minis.maxBytes * fraction.coerceIn(0f, 1f)).toLong())
    }

    /** Hard eviction: every decoded frame goes, download state stays. */
    fun evictImages() {
        images.evictAll()
        minis.evictAll()
    }

    /** Status-sheet / logcat line: `images 12/160 · 21.4/48.0 MB · 143 evicted`. */
    fun cacheStats(): String {
        fun mb(v: Long) = String.format(Locale.ROOT, "%.1f", v / 1024.0 / 1024.0)
        return "images ${images.count}/${images.maxCount} · ${mb(images.bytes)}/${mb(images.maxBytes)} MB · ${images.evictions} evicted"
    }

    fun clear() {
        evictImages()
        _files.value = emptyMap()
        synchronized(locks) { locks.clear() }
    }
}
