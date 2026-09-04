package ca.lucianlabs.tgsocial.repo

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.FileDataSource
import androidx.media3.datasource.TransferListener
import ca.lucianlabs.tgsocial.model.FileRef
import ca.lucianlabs.tgsocial.td.TelegramClient
import kotlinx.coroutines.runBlocking
import java.io.IOException
import java.io.RandomAccessFile

/**
 * PRODUCT §2.11 — streaming playback straight out of TDLib: a media3 DataSource that reads the TDLib-managed
 * local file and, when a requested range is not on disk yet, asks TDLib for exactly that part
 * (`downloadFile(offset, limit, synchronous = true)`). The player starts as soon as the downloaded prefix allows.
 * Runs on ExoPlayer's loader thread, so the blocking waits never touch the UI.
 */
@UnstableApi
class TdDataSource(private val tg: TelegramClient, private val priority: Int) : BaseDataSource(true) {
    companion object {
        const val SCHEME = "td"
        fun uri(ref: FileRef): Uri = Uri.parse("$SCHEME://file/${ref.id}")
        private const val CHUNK = 512 * 1024L
    }

    /**
     * PRODUCT §2.22.4 — the demo's clips are generated files on disk, and they play through the same player
     * this factory feeds. A `file://` spec is handed to media3's own `FileDataSource` instead of being parsed
     * as a TDLib file id: the scheme decides, so nothing had to be told which world it is in.
     */
    class Factory(private val tg: TelegramClient, private val priority: Int) : DataSource.Factory {
        override fun createDataSource(): DataSource = SchemeDataSource(tg, priority)
    }

    /** Delegates by scheme, because the URI is only known at `open` and the factory has to answer before that. */
    private class SchemeDataSource(private val tg: TelegramClient, private val priority: Int) : DataSource {
        private var delegate: DataSource? = null
        private val transfers = ArrayList<TransferListener>()

        private fun pick(dataSpec: DataSpec): DataSource {
            val source = if (dataSpec.uri.scheme == SCHEME) TdDataSource(tg, priority) else FileDataSource()
            transfers.forEach { source.addTransferListener(it) }
            delegate = source
            return source
        }

        override fun addTransferListener(transferListener: TransferListener) {
            transfers += transferListener
            delegate?.addTransferListener(transferListener)
        }

        override fun open(dataSpec: DataSpec): Long = pick(dataSpec).open(dataSpec)
        override fun read(buffer: ByteArray, offset: Int, length: Int): Int = delegate?.read(buffer, offset, length) ?: C.RESULT_END_OF_INPUT
        override fun getUri(): Uri? = delegate?.uri
        override fun getResponseHeaders(): Map<String, List<String>> = delegate?.responseHeaders ?: emptyMap()
        override fun close() {
            delegate?.close()
            delegate = null
        }
    }

    private var spec: DataSpec? = null
    private var fileId = 0
    private var raf: RandomAccessFile? = null
    private var path: String? = null
    private var position = 0L
    private var remaining = 0L

    override fun open(dataSpec: DataSpec): Long {
        spec = dataSpec
        fileId = dataSpec.uri.lastPathSegment?.toIntOrNull() ?: throw IOException("Not a TDLib file uri: ${dataSpec.uri}")
        transferInitializing(dataSpec)
        val file = getFile() ?: throw IOException("TDLib file $fileId unavailable")
        val size = if (file.size > 0) file.size else file.expectedSize
        position = dataSpec.position
        remaining = if (dataSpec.length != C.LENGTH_UNSET.toLong()) dataSpec.length else (size - position).coerceAtLeast(0)
        ensure(position, 1L)
        raf = RandomAccessFile(path ?: throw IOException("TDLib file $fileId has no local path"), "r").apply { seek(position) }
        transferStarted(dataSpec)
        return if (dataSpec.length != C.LENGTH_UNSET.toLong() || size > 0) remaining else C.LENGTH_UNSET.toLong()
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (remaining <= 0L) return C.RESULT_END_OF_INPUT
        val want = minOf(length.toLong(), remaining)
        ensure(position, want)
        val reader = raf ?: return C.RESULT_END_OF_INPUT
        reader.seek(position)
        val n = reader.read(buffer, offset, want.toInt())
        if (n <= 0) return C.RESULT_END_OF_INPUT
        position += n
        remaining -= n
        bytesTransferred(n)
        return n
    }

    override fun getUri(): Uri? = spec?.uri

    override fun close() {
        runCatching { raf?.close() }
        raf = null
        if (spec != null) {
            spec = null
            transferEnded()
        }
    }

    private fun getFile(): dev.g000sha256.tdl.dto.File? =
        runBlocking { tg.callOrNull(20_000L) { getFile(fileId = fileId) } }

    /** Blocks until [pos, pos+len) is on disk, pulling missing parts at this source's priority. */
    private fun ensure(pos: Long, len: Long) {
        var file = getFile() ?: throw IOException("TDLib file $fileId unavailable")
        var rounds = 0
        while (true) {
            val local = file.local
            if (local.path.isNotEmpty()) path = local.path
            val covered = local.isDownloadingCompleted ||
                (pos >= local.downloadOffset && pos + len <= local.downloadOffset + local.downloadedPrefixSize)
            if (covered && path != null) return
            if (rounds++ > 512) throw IOException("TDLib file $fileId never covered [$pos, ${pos + len})")
            file = runBlocking {
                tg.callOrNull(120_000L) {
                    downloadFile(fileId = fileId, priority = priority, offset = pos, limit = maxOf(len, CHUNK), synchronous = true)
                }
            } ?: throw IOException("TDLib download of file $fileId failed")
        }
    }
}
