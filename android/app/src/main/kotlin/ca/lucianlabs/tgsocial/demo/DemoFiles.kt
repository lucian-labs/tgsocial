package ca.lucianlabs.tgsocial.demo

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.graphics.Typeface
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import ca.lucianlabs.tgsocial.model.FileRef
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.random.Random

/**
 * PRODUCT §2.22.1 — the generated world, as bytes on disk.
 *
 * Everything the demo shows is produced here from the item key as a seed and written into the app's own cache
 * directory, so the media path a fixture takes is the **real** one: `MediaRepo` decodes a local file,
 * `AudioStripRepo` analyses a local file, ExoPlayer plays a local file. Nothing is bundled and nothing is
 * fetched, which is the §2.22.4 claim — a fixture has no file id anything could download.
 *
 * Failure is always null. A device whose encoder will not make an H.264 stream is not an exceptional case
 * worth surfacing: the poster stands and the rest of the demo is unaffected.
 */
object DemoFiles {

    private const val DIR = "demo-media"

    private lateinit var root: File
    private val building = HashMap<String, Any>()

    /**
     * Called once when the demo starts. §2.22.5 — "nothing is saved on this device", which the demo sheet says
     * to the reader in those words, so the wipe happens at both ends: [detach] clears the directory on
     * `Leave Demo`, and this clears whatever a process death left behind. Only `Leave Demo` runs [detach]; a
     * reviewer who swipes the app away mid-demo, or a low-memory kill, otherwise leaves the generated plates
     * and a 10.6 MB WAV on disk indefinitely.
     */
    @Synchronized
    fun attach(cacheDir: File) {
        root = File(cacheDir, DIR).apply { runCatching { deleteRecursively() }; mkdirs() }
    }

    @Synchronized
    fun detach() {
        if (::root.isInitialized) runCatching { root.deleteRecursively() }
        building.clear()
    }

    private val attached: Boolean get() = ::root.isInitialized && root.exists()

    private fun fileFor(key: String, ext: String): File =
        File(root, key.replace('/', '_').replace('·', '.') + "." + ext)

    /** One lock per key, so two composables asking for the same plate at once generate it once. */
    @Synchronized
    private fun lockFor(key: String): Any = building.getOrPut(key) { Any() }

    /**
     * The path of a fixture file **only if it has already been generated**. Cheap and non-blocking, for the
     * main-thread callers (building a `MediaItem`) that must not start an encode.
     */
    fun existing(ref: FileRef): String? {
        if (!DemoMedia.isDemo(ref) || !attached) return null
        val key = DemoMedia.keyOf(ref)
        return sequenceOf("png", "wav", "mp4", "pdf")
            .map { fileFor(key, it) }
            .firstOrNull { it.exists() && it.length() > 0 }
            ?.absolutePath
    }

    /**
     * The local path of a fixture file, generating it on first ask. Blocking: every caller is already on a
     * background dispatcher (`MediaRepo.localPath`, `AudioStripRepo`, the inline player's `LaunchedEffect`).
     */
    fun path(ref: FileRef): String? {
        if (!DemoMedia.isDemo(ref) || !attached) return null
        val key = DemoMedia.keyOf(ref)
        return synchronized(lockFor(key)) {
            runCatching {
                when {
                    key.endsWith("·1") && ref.width == 0 && ref.height == 0 -> audioOrDocument(key)
                    // Video and the animation are the two moving items; both are `video/mp4` fixtures.
                    key.endsWith("·1") && (key.startsWith("demo_slow_radio/95") || key.startsWith("demo_slow_radio/88")) -> video(key, ref)
                    else -> plate(key, ref)
                }?.absolutePath
            }.getOrNull()
        }
    }

    // ------------------------------------------------------------------ plates

    /**
     * §2.22.1 — "a linear gradient between two House Pour tokens chosen by the seed, a handful of seeded
     * circles and bars over it, and the item key in mono `faint` bottom-left". Deterministic per platform; not
     * pixel-identical between platforms, which does not matter — the contract is the same world, not the same
     * pixels.
     */
    private fun plate(key: String, ref: FileRef): File? {
        val out = fileFor(key, "png")
        if (out.exists()) return out
        val w = ref.width.coerceIn(64, 1440)
        val h = ref.height.coerceIn(64, 1440)
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        drawPlate(Canvas(bmp), w, h, key)
        out.outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bmp.recycle()
        return out
    }

    /** Shared by the plates and the video frames, so a clip's poster and its first frame are the same picture. */
    fun drawPlate(canvas: Canvas, w: Int, h: Int, key: String, phase: Float = 0f) {
        val (a, b) = DemoMedia.plateColors(key)
        val rnd = Random(DemoMedia.seed(key))
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.shader = LinearGradient(0f, 0f, w.toFloat(), h.toFloat(), a, b, Shader.TileMode.CLAMP)
        canvas.drawRect(0f, 0f, w.toFloat(), h.toFloat(), paint)
        paint.shader = null
        repeat(5) {
            paint.color = (0x30FFFFFF.toInt() and (0xFF000000.toInt() or rnd.nextInt())) or 0x22000000
            paint.alpha = 26 + rnd.nextInt(40)
            val cx = rnd.nextFloat() * w
            val cy = rnd.nextFloat() * h
            canvas.drawCircle(cx, cy, (0.08f + rnd.nextFloat() * 0.22f) * minOf(w, h), paint)
        }
        repeat(3) {
            paint.alpha = 18 + rnd.nextInt(30)
            val y = rnd.nextFloat() * h
            val bh = (0.02f + rnd.nextFloat() * 0.06f) * h
            canvas.drawRect(0f, y, w.toFloat(), y + bh, paint)
        }
        // The bar the clips animate; at phase 0 it sits at the left edge, which is what the poster shows.
        paint.color = 0xFFE9E3D6.toInt()
        paint.alpha = 120
        val barX = phase * (w * 1.2f) - w * 0.1f
        canvas.drawRect(barX, 0f, barX + w * 0.06f, h.toFloat(), paint)
        // §2.22 item 3 — the key, in the corner, so a single cropped image still says what it is.
        val label = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xB3F5F0E6.toInt()
            textSize = (h * 0.05f).coerceIn(11f, 28f)
            typeface = Typeface.MONOSPACE
        }
        canvas.drawText(key, h * 0.04f, h - h * 0.04f, label)
    }

    // ------------------------------------------------------------------ audio and the document

    /** The two audio fixtures are 16-bit PCM WAV; the document fixture is a real one-page PDF. */
    private fun audioOrDocument(key: String): File? = when {
        key.startsWith("demo_press_run/71") -> wav(key, 47)
        key.startsWith("demo_slow_radio/101") -> wav(key, 222)
        key.startsWith("demo_wren_bench/17") -> pdfDocument(key)
        else -> null
    }

    private fun wav(key: String, seconds: Int): File? {
        val out = fileFor(key, "wav")
        if (out.exists()) return out
        val samples = DemoMedia.pcm(key, seconds)
        val rate = DemoMedia.SAMPLE_RATE
        val data = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (s in samples) data.putShort((s.coerceIn(-1f, 1f) * 32_767f).toInt().toShort())
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        val dataLen = data.capacity()
        header.put("RIFF".toByteArray()).putInt(36 + dataLen).put("WAVE".toByteArray())
        header.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1)
        header.putInt(rate).putInt(rate * 2).putShort(2).putShort(16)
        header.put("data".toByteArray()).putInt(dataLen)
        out.outputStream().use { it.write(header.array()); it.write(data.array()) }
        return out
    }

    /**
     * The document row's file: a real one-page PDF, hand-assembled, so §2.11's in-app PDF viewer opens it
     * rather than choking on a text file wearing a `.pdf` name. §2.22.1's `2.4 MB` is the fixture's own size
     * field, which is what the row prints — padding a file out to it would be 2.4 MB nobody looks at.
     */
    private fun pdfDocument(key: String): File? {
        val out = fileFor(key, "pdf")
        if (out.exists()) return out
        val lines = listOf(
            "tide-table-1971 - a demo fixture",
            "Invented. There is no 1971 tide table here,",
            "and nothing in the demo is on Telegram.",
        )
        val content = buildString {
            append("BT /F1 16 Tf 60 720 Td 20 TL\n")
            lines.forEach { append("(").append(it).append(") Tj T*\n") }
            append("ET\n")
        }
        val objects = listOf(
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length ${content.length} >>\nstream\n$content\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>",
        )
        val sb = StringBuilder("%PDF-1.4\n")
        val offsets = ArrayList<Int>()
        objects.forEachIndexed { i, body ->
            offsets += sb.length
            sb.append(i + 1).append(" 0 obj\n").append(body).append("\nendobj\n")
        }
        val xref = sb.length
        sb.append("xref\n0 ").append(objects.size + 1).append("\n0000000000 65535 f \n")
        offsets.forEach { sb.append(String.format("%010d 00000 n \n", it)) }
        sb.append("trailer\n<< /Size ").append(objects.size + 1).append(" /Root 1 0 R >>\nstartxref\n").append(xref).append("\n%%EOF\n")
        out.writeText(sb.toString())
        return out
    }

    // ------------------------------------------------------------------ video and the animation

    private const val FPS = 12

    /**
     * §2.22.1 — "video and the animation are procedural frame sources": a moving House Pour bar at 12 fps
     * against a real transport, poster, duration pill, scrubber and full-screen player. Encoded here into an
     * H.264 file because that is what the real transport plays — shipping an mp4 into three app bundles to
     * prove a transport works is more binary than the feature is worth, but *generating* one costs nothing at
     * rest and exercises exactly the path a downloaded clip takes.
     */
    private fun video(key: String, ref: FileRef): File? {
        val out = fileFor(key, "mp4")
        if (out.exists()) return out
        val seconds = if (key.startsWith("demo_slow_radio/95")) 18 else 2
        // Encoders want even dimensions; the fixture aspects are chosen to already be even.
        val w = (ref.width.coerceIn(160, 1280) / 2) * 2
        val h = (ref.height.coerceIn(160, 1280) / 2) * 2
        return runCatching { encode(out, key, w, h, seconds) }.getOrNull()?.let { if (it) out else null.also { _ -> out.delete() } }
    }

    private fun encode(out: File, key: String, w: Int, h: Int, seconds: Int): Boolean {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            setInteger(MediaFormat.KEY_BIT_RATE, w * h * 4)
            setInteger(MediaFormat.KEY_FRAME_RATE, FPS)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        val muxer = MediaMuxer(out.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var track = -1
        var muxing = false
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            val info = MediaCodec.BufferInfo()
            val total = seconds * FPS
            val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bmp)
            val pixels = IntArray(w * h)
            var frame = 0
            var done = false
            while (!done) {
                if (frame <= total) {
                    val index = codec.dequeueInputBuffer(10_000L)
                    if (index >= 0) {
                        val last = frame == total
                        if (!last) {
                            drawPlate(canvas, w, h, key, phase = frame.toFloat() / total)
                            bmp.getPixels(pixels, 0, w, 0, 0, w, h)
                            fillI420(codec, index, pixels, w, h)
                        }
                        val ptsUs = frame.toLong() * 1_000_000L / FPS
                        val size = if (last) 0 else w * h * 3 / 2
                        codec.queueInputBuffer(index, 0, size, ptsUs, if (last) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0)
                        frame++
                    }
                }
                val outIndex = codec.dequeueOutputBuffer(info, 10_000L)
                when {
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        track = muxer.addTrack(codec.outputFormat)
                        muxer.start()
                        muxing = true
                    }
                    outIndex >= 0 -> {
                        val buffer = codec.getOutputBuffer(outIndex)
                        if (buffer != null && muxing && info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                            muxer.writeSampleData(track, buffer, info)
                        }
                        codec.releaseOutputBuffer(outIndex, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) done = true
                    }
                }
            }
            bmp.recycle()
            return muxing
        } catch (_: Exception) {
            return false
        } finally {
            runCatching { codec.stop() }
            runCatching { codec.release() }
            runCatching { if (muxing) muxer.stop() }
            runCatching { muxer.release() }
        }
    }

    /**
     * ARGB → I420 through `getInputImage`, which hands back the planes with their real row and pixel strides.
     * Doing it that way rather than assuming NV12 is what makes this work on encoders that want planar.
     */
    private fun fillI420(codec: MediaCodec, index: Int, pixels: IntArray, w: Int, h: Int) {
        val image = codec.getInputImage(index) ?: return
        val y = image.planes[0]
        val u = image.planes[1]
        val v = image.planes[2]
        val yBuf = y.buffer
        val uBuf = u.buffer
        val vBuf = v.buffer
        for (row in 0 until h) {
            for (col in 0 until w) {
                val p = pixels[row * w + col]
                val r = (p shr 16) and 0xFF
                val g = (p shr 8) and 0xFF
                val b = p and 0xFF
                val yy = ((66 * r + 129 * g + 25 * b + 128) shr 8) + 16
                yBuf.put(row * y.rowStride + col * y.pixelStride, yy.coerceIn(0, 255).toByte())
                if (row % 2 == 0 && col % 2 == 0) {
                    val uu = ((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128
                    val vv = ((112 * r - 94 * g - 18 * b + 128) shr 8) + 128
                    val cr = row / 2
                    val cc = col / 2
                    uBuf.put(cr * u.rowStride + cc * u.pixelStride, uu.coerceIn(0, 255).toByte())
                    vBuf.put(cr * v.rowStride + cc * v.pixelStride, vv.coerceIn(0, 255).toByte())
                }
            }
        }
    }
}
