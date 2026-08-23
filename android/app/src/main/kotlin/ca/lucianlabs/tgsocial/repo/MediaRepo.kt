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
import androidx.compose.ui.graphics.asImageBitmap
import androidx.core.content.FileProvider
import ca.lucianlabs.tgsocial.model.FileRef
import ca.lucianlabs.tgsocial.td.TelegramClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.util.Collections

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
class MediaRepo(private val tg: TelegramClient, private val activity: ActivityRegistry) {
    companion object {
        const val PRIORITY_VISIBLE = 1
        const val PRIORITY_TAPPED = 32
    }

    private val images: MutableMap<String, ImageBitmap> = Collections.synchronizedMap(object : LinkedHashMap<String, ImageBitmap>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ImageBitmap>?): Boolean = size > 120
    })
    private val minis: MutableMap<String, ImageBitmap> = Collections.synchronizedMap(object : LinkedHashMap<String, ImageBitmap>(32, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ImageBitmap>?): Boolean = size > 160
    })
    private val locks = HashMap<String, Mutex>()

    private val _files = MutableStateFlow<Map<Int, FileState>>(emptyMap())
    val files: StateFlow<Map<Int, FileState>> = _files.asStateFlow()

    init {
        tg.scope.launch {
            tg.files.collect { f ->
                _files.value = _files.value + (f.id to f.state())
            }
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

    /** The local path when the file is already complete on disk, else null. */
    suspend fun localPath(ref: FileRef): String? {
        ref.localPath?.takeIf { File(it).exists() }?.let { return it }
        state(ref)?.path?.takeIf { File(it).exists() }?.let { return it }
        val f = tg.callOrNull(10_000L) { getFile(fileId = ref.id) } ?: return null
        _files.value = _files.value + (f.id to f.state())
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
            if (started != null) _files.value = _files.value + (started.id to started.state())
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
            if (f != null) _files.value = _files.value + (f.id to f.state())
        }
    }

    fun cancel(ref: FileRef) {
        tg.scope.launch {
            tg.callOrNull { cancelDownloadFile(fileId = ref.id, onlyIfPending = false) }
            _files.value = _files.value + (ref.id to (state(ref)?.copy(active = false) ?: FileState(ref.id)))
        }
    }

    fun cached(ref: FileRef, targetWidthPx: Int): ImageBitmap? = images[key(ref, targetWidthPx)]

    private fun key(ref: FileRef, w: Int) = "${ref.uniqueId}@${bucket(w)}"
    private fun bucket(w: Int) = when { w <= 96 -> 96; w <= 256 -> 256; w <= 720 -> 720; else -> 1440 }

    suspend fun image(ref: FileRef, targetWidthPx: Int, priority: Int = PRIORITY_VISIBLE): ImageBitmap? {
        val k = key(ref, targetWidthPx)
        images[k]?.let { return it }
        val mutex = synchronized(locks) { locks.getOrPut(k) { Mutex() } }
        return mutex.withLock {
            images[k]?.let { return@withLock it }
            val path = localPath(ref) ?: download(ref, priority, "Downloading photo") ?: return@withLock null
            val bmp = withContext(Dispatchers.IO) { decode(path, bucket(targetWidthPx)) } ?: return@withLock null
            bmp.also { images[k] = it }
        }
    }

    /** Minithumbnail (base64 JPEG) decoded for the blur-up placeholder. */
    fun mini(b64: String?): ImageBitmap? {
        if (b64.isNullOrBlank()) return null
        minis[b64]?.let { return it }
        return runCatching {
            val bytes = java.util.Base64.getDecoder().decode(b64)
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
        }.getOrNull()?.also { minis[b64] = it }
    }

    /** Decode off the main thread; ImageDecoder on 28+ (webp and friends), BitmapFactory before. */
    private fun decode(path: String, targetWidth: Int): ImageBitmap? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            return runCatching {
                val source = ImageDecoder.createSource(File(path))
                ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                    decoder.isMutableRequired = false
                    val w = info.size.width
                    if (w > targetWidth) {
                        val h = info.size.height * targetWidth / w
                        decoder.setTargetSize(targetWidth, h.coerceAtLeast(1))
                    }
                }.asImageBitmap()
            }.getOrNull() ?: decodeLegacy(path, targetWidth)
        }
        return decodeLegacy(path, targetWidth)
    }

    private fun decodeLegacy(path: String, targetWidth: Int): ImageBitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0) return null
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= targetWidth) sample *= 2
        val opts = BitmapFactory.Options().apply { inSampleSize = sample; inPreferredConfig = Bitmap.Config.ARGB_8888 }
        return BitmapFactory.decodeFile(path, opts)?.asImageBitmap()
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
                            val w = widthPx.coerceAtLeast(1)
                            val h = (page.height.toFloat() / page.width * w).toInt().coerceAtLeast(1)
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

    fun clear() {
        images.clear()
        minis.clear()
        _files.value = emptyMap()
    }
}
