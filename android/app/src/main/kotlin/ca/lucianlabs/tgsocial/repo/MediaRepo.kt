package ca.lucianlabs.tgsocial.repo

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import ca.lucianlabs.tgsocial.model.FileRef
import ca.lucianlabs.tgsocial.td.TelegramClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Collections

/** PROTOCOL §4.10 — download via TDLib, decode at display size, cache by `remote.uniqueId`. */
class MediaRepo(private val tg: TelegramClient) {
    private val images: MutableMap<String, ImageBitmap> = Collections.synchronizedMap(object : LinkedHashMap<String, ImageBitmap>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ImageBitmap>?): Boolean = size > 120
    })
    private val locks = HashMap<String, Mutex>()

    fun cached(ref: FileRef, targetWidthPx: Int): ImageBitmap? = images[key(ref, targetWidthPx)]

    private fun key(ref: FileRef, w: Int) = "${ref.uniqueId}@${bucket(w)}"
    private fun bucket(w: Int) = when { w <= 96 -> 96; w <= 256 -> 256; w <= 720 -> 720; else -> 1440 }

    suspend fun image(ref: FileRef, targetWidthPx: Int): ImageBitmap? {
        val k = key(ref, targetWidthPx)
        images[k]?.let { return it }
        val mutex = synchronized(locks) { locks.getOrPut(k) { Mutex() } }
        return mutex.withLock {
            images[k]?.let { return@withLock it }
            val path = ref.localPath?.takeIf { File(it).exists() } ?: tg.awaitDownload(ref.id) ?: return@withLock null
            val bmp = withContext(Dispatchers.IO) { decode(path, bucket(targetWidthPx)) } ?: return@withLock null
            bmp.also { images[k] = it }
        }
    }

    private fun decode(path: String, targetWidth: Int): ImageBitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0) return null
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= targetWidth) sample *= 2
        val opts = BitmapFactory.Options().apply { inSampleSize = sample; inPreferredConfig = Bitmap.Config.ARGB_8888 }
        return BitmapFactory.decodeFile(path, opts)?.asImageBitmap()
    }

    fun clear() = images.clear()
}
