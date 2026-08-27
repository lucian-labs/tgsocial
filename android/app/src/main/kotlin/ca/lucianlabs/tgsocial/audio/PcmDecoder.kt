package ca.lucianlabs.tgsocial.audio

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * The one Android-flavoured step of the analysis: a local media file → mono PCM at [SpectrogramSpec.RATE].
 *
 * `MediaExtractor` + `MediaCodec` in synchronous mode. Synchronous because this already runs on a background
 * dispatcher and owns its thread for the duration — the async callback form buys nothing here and costs a
 * handler thread and a state machine.
 *
 * **Every failure returns null.** A codec this device lacks, a truncated download, a container whose audio
 * track is a format nobody can decode: none of that is exceptional enough to log loudly or to surface, and
 * §2.11.1 says what happens next — "on any decode failure, fall back to the amplitude-only silhouette".
 */
object PcmDecoder {

    private const val TIMEOUT_US = 10_000L

    /**
     * Decode [path] to mono at [targetRate], stopping at [maxSamples] (the duration cap in samples, so a
     * container that lies about its duration still cannot run away with the CPU).
     *
     * [maxSamples] defaults to the §2.11.1 ceiling for a caller that genuinely knows nothing about the clip,
     * but every caller that has a duration should pass `SpectrogramSpec.samplesFor(duration)` instead: the
     * ceiling is what the decode is allowed to keep, and at ten minutes that is 36.6 MB of floats.
     *
     * Channels are averaged rather than taking the left one: a stereo mix with the vocal panned wide reads
     * as half a take if you throw a channel away.
     */
    fun decodeMono(
        path: String,
        targetRate: Int = SpectrogramSpec.RATE,
        maxSamples: Int = SpectrogramSpec.MAX_SAMPLES,
    ): FloatArray? {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(path)
            var track = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    track = i
                    format = f
                    break
                }
            }
            val input = format ?: return null
            val mime = input.getString(MediaFormat.KEY_MIME) ?: return null
            extractor.selectTrack(track)

            var sourceRate = input.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = input.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceAtLeast(1)
            if (sourceRate <= 0) return null

            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(input, null, null, 0)
            codec.start()

            var decimator = Decimator(sourceRate, targetRate, maxSamples)
            var encoding = AudioFormat.ENCODING_PCM_16BIT
            val info = MediaCodec.BufferInfo()
            var sawInputEnd = false
            var sawOutputEnd = false

            while (!sawOutputEnd && !decimator.full) {
                if (!sawInputEnd) {
                    val index = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (index >= 0) {
                        val buffer = codec.getInputBuffer(index)
                        val read = if (buffer == null) -1 else extractor.readSampleData(buffer, 0)
                        if (read < 0) {
                            codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            sawInputEnd = true
                        } else {
                            codec.queueInputBuffer(index, 0, read, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                when (val index = codec.dequeueOutputBuffer(info, TIMEOUT_US)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        // The decoder's real output geometry, which need not match the track's declared one
                        // (a decoder is allowed to resample, and several do). Re-derive everything from it.
                        //
                        // A fresh decimator ONLY when the rate actually moved — its ratio is fixed at
                        // construction, and nothing else about it depends on the format. This event fires on
                        // essentially every decode, so replacing an equivalent decimator here bought a second
                        // live buffer for as long as the old local was still referenced.
                        val out = codec.outputFormat
                        val outRate = runCatching { out.getInteger(MediaFormat.KEY_SAMPLE_RATE) }.getOrDefault(sourceRate)
                        val outChannels = runCatching { out.getInteger(MediaFormat.KEY_CHANNEL_COUNT) }.getOrDefault(channels)
                        encoding = runCatching { out.getInteger(MediaFormat.KEY_PCM_ENCODING) }.getOrDefault(AudioFormat.ENCODING_PCM_16BIT)
                        if (outRate > 0 && outRate != sourceRate) {
                            sourceRate = outRate
                            decimator = Decimator(sourceRate, targetRate, maxSamples)
                        }
                        channels = outChannels.coerceAtLeast(1)
                    }

                    MediaCodec.INFO_TRY_AGAIN_LATER -> Unit

                    else -> {
                        if (index >= 0) {
                            if (info.size > 0) {
                                val buffer = codec.getOutputBuffer(index)
                                if (buffer != null) feed(buffer, info, channels, encoding, decimator)
                            }
                            codec.releaseOutputBuffer(index, false)
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) sawOutputEnd = true
                        }
                    }
                }
            }

            val pcm = decimator.result()
            return if (pcm.isEmpty()) null else pcm
        } catch (t: Throwable) {
            // Includes MediaCodec.CodecException, IllegalStateException from a codec that died mid-stream,
            // IOException from a file the download truncated, and OOM from a pathological container.
            return null
        } finally {
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            runCatching { extractor.release() }
        }
    }

    private fun feed(buffer: ByteBuffer, info: MediaCodec.BufferInfo, channels: Int, encoding: Int, into: Decimator) {
        buffer.position(info.offset)
        buffer.limit(info.offset + info.size)
        val pcm = buffer.slice().order(ByteOrder.nativeOrder())
        when (encoding) {
            AudioFormat.ENCODING_PCM_FLOAT -> {
                val floats = pcm.asFloatBuffer()
                val frames = floats.remaining() / channels
                for (f in 0 until frames) {
                    if (into.full) return
                    var sum = 0f
                    for (c in 0 until channels) sum += floats.get(f * channels + c)
                    into.push(sum / channels)
                }
            }

            AudioFormat.ENCODING_PCM_8BIT -> {
                val frames = pcm.remaining() / channels
                for (f in 0 until frames) {
                    if (into.full) return
                    var sum = 0f
                    for (c in 0 until channels) sum += ((pcm.get(f * channels + c).toInt() and 0xFF) - 128) / 128f
                    into.push(sum / channels)
                }
            }

            else -> {
                val shorts = pcm.asShortBuffer()
                val frames = shorts.remaining() / channels
                for (f in 0 until frames) {
                    if (into.full) return
                    var sum = 0f
                    for (c in 0 until channels) sum += shorts.get(f * channels + c) / 32768f
                    into.push(sum / channels)
                }
            }
        }
    }
}
